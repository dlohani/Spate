package localapi

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"math/rand"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"cascade/internal/job"
)

func TestAddRequiresTokenAndEnqueues(t *testing.T) {
	// Origin server with range support.
	data := make([]byte, 1<<20)
	rand.New(rand.NewSource(3)).Read(data)
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "f.bin", time.Now(), bytes.NewReader(data))
	}))
	defer origin.Close()

	mgr := job.New(2)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = mgr.Serve(ctx) }()

	dir := t.TempDir()
	s := New(mgr, "secret-token", dir)
	addr, err := s.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	base := "http://" + addr

	body, _ := json.Marshal(addRequest{URL: origin.URL + "/f.bin", Filename: "out.bin"})

	// Without token: 401.
	resp, err := http.Post(base+"/add", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("no token: got %d, want 401", resp.StatusCode)
	}

	// With token: 200 + id.
	req, _ := http.NewRequest(http.MethodPost, base+"/add", bytes.NewReader(body))
	req.Header.Set("X-Cascade-Token", "secret-token")
	req.Header.Set("Content-Type", "application/json")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]string
	json.NewDecoder(resp.Body).Decode(&got)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || got["id"] == "" {
		t.Fatalf("with token: status %d id %q", resp.StatusCode, got["id"])
	}

	// The enqueued job should complete and write the file.
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if st, ok := mgr.Status(got["id"]); ok && st.State == job.Done {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	out := filepath.Join(dir, "out.bin")
	b, err := os.ReadFile(out)
	if err != nil || !bytes.Equal(b, data) {
		t.Fatalf("enqueued download did not complete correctly: err=%v len=%d", err, len(b))
	}
}

func TestWebOriginRejectedExtensionAllowed(t *testing.T) {
	s := New(job.New(1), "tok", t.TempDir())
	if _, err := s.Start(); err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	body := []byte(`{"url":"http://example.invalid/f.bin"}`)
	do := func(origin string) int {
		req, _ := http.NewRequest(http.MethodPost, "http://"+s.Addr()+"/add", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Cascade-Token", "tok")
		if origin != "" {
			req.Header.Set("Origin", origin)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	if c := do("https://evil.example"); c != http.StatusForbidden {
		t.Errorf("web origin: got %d, want 403", c)
	}
	if c := do("chrome-extension://abcdefghijklmnop"); c != http.StatusOK {
		t.Errorf("extension origin: got %d, want 200", c)
	}
	if c := do(""); c != http.StatusOK {
		t.Errorf("no origin (local client): got %d, want 200", c)
	}
}

func TestPairAllowDeclineAndHeartbeat(t *testing.T) {
	s := New(job.New(1), "the-token", t.TempDir())
	if _, err := s.Start(); err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	get := func(path, origin string) (int, string) {
		req, _ := http.NewRequest(http.MethodGet, "http://"+s.Addr()+path, nil)
		req.Header.Set("X-Cascade-Client", "extension")
		if origin != "" {
			req.Header.Set("Origin", origin)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b)
	}

	// No PairFunc: pairing unavailable.
	if c, _ := get("/pair", "chrome-extension://x"); c != http.StatusNotFound {
		t.Errorf("no PairFunc: got %d, want 404", c)
	}
	// Declined by the user.
	s.PairFunc = func() bool { return false }
	if c, _ := get("/pair", "chrome-extension://x"); c != http.StatusForbidden {
		t.Errorf("declined: got %d, want 403", c)
	}
	// Web page may never even prompt.
	s.PairFunc = func() bool { t.Error("PairFunc must not run for a web origin"); return true }
	if c, _ := get("/pair", "https://evil.example"); c != http.StatusForbidden {
		t.Errorf("web origin pair: got %d, want 403", c)
	}
	// Allowed: token released.
	s.PairFunc = func() bool { return true }
	c, body := get("/pair", "chrome-extension://x")
	if c != http.StatusOK || !strings.Contains(body, "the-token") {
		t.Errorf("allowed: got %d %q, want 200 with token", c, body)
	}
	// Heartbeat recorded from the extension's ping.
	if s.LastExtensionContact().IsZero() {
		t.Error("expected extension contact to be recorded")
	}
}

func TestAddDedupesSameOutputPath(t *testing.T) {
	mgr := job.New(1)
	// No Serve/Run: the first job stays Pending, i.e. non-terminal.
	s := New(mgr, "tok", t.TempDir())
	if _, err := s.Start(); err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	post := func() map[string]any {
		body := []byte(`{"url":"http://example.invalid/big.iso","filename":"big.iso"}`)
		req, _ := http.NewRequest(http.MethodPost, "http://"+s.Addr()+"/add", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Cascade-Token", "tok")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var m map[string]any
		json.NewDecoder(resp.Body).Decode(&m)
		return m
	}
	first := post()
	second := post()
	if first["id"] != second["id"] || second["existing"] != true {
		t.Fatalf("expected second add to reuse job %v, got %v", first, second)
	}
	if n := len(mgr.Statuses()); n != 1 {
		t.Fatalf("expected 1 job, got %d", n)
	}
}

func TestPing(t *testing.T) {
	s := New(job.New(1), "t", t.TempDir())
	if _, err := s.Start(); err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	resp, err := http.Get("http://" + s.Addr() + "/ping")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(b), "cascade") {
		t.Fatalf("ping body = %q", b)
	}
}
