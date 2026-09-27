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
