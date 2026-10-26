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

// Every test binds the same fixed ports, so a keep-alive connection pooled by
// one test can point at a server the previous test already closed; a POST on
// such a connection fails with EOF and is not retried. Do not pool.
func init() { http.DefaultTransport.(*http.Transport).DisableKeepAlives = true }

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

// okOrigin serves a small range-capable file, for hand-off tests that need a
// URL the app's fetchability probe accepts.
func okOrigin(t *testing.T) *httptest.Server {
	t.Helper()
	data := make([]byte, 64<<10)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "f.bin", time.Now(), bytes.NewReader(data))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func TestWebOriginRejectedExtensionAllowed(t *testing.T) {
	origin := okOrigin(t)
	s := New(job.New(1), "tok", t.TempDir())
	if _, err := s.Start(); err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	body := []byte(`{"url":"` + origin.URL + `/f.bin"}`)
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
	origin := okOrigin(t)
	mgr := job.New(1)
	// No Serve/Run: the first job stays Pending, i.e. non-terminal.
	s := New(mgr, "tok", t.TempDir())
	if _, err := s.Start(); err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	post := func() map[string]any {
		body := []byte(`{"url":"` + origin.URL + `/big.iso","filename":"big.iso"}`)
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

func TestJobsListsQueueWithState(t *testing.T) {
	mgr := job.New(1) // not driven: the job stays pending
	s := New(mgr, "tok", t.TempDir())
	if _, err := s.Start(); err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if _, err := mgr.Add(job.Spec{URL: "http://example.invalid/x.bin", Out: "/tmp/x.bin"}); err != nil {
		t.Fatal(err)
	}
	get := func(token string) (int, []map[string]any) {
		req, _ := http.NewRequest(http.MethodGet, "http://"+s.Addr()+"/jobs", nil)
		if token != "" {
			req.Header.Set("X-Cascade-Token", token)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var out []map[string]any
		json.NewDecoder(resp.Body).Decode(&out)
		return resp.StatusCode, out
	}
	if c, _ := get(""); c != http.StatusUnauthorized {
		t.Errorf("no token: got %d, want 401", c)
	}
	c, jobs := get("tok")
	if c != http.StatusOK || len(jobs) != 1 {
		t.Fatalf("got %d with %d jobs, want 200 with 1", c, len(jobs))
	}
	j := jobs[0]
	if j["state"] != "pending" || j["url"] != "http://example.invalid/x.bin" || j["out"] != "/tmp/x.bin" {
		t.Errorf("unexpected job payload: %v", j)
	}
}

func TestAddRefusesUnfetchableURL(t *testing.T) {
	// An origin that answers 403 to a plain GET (session-bound / POST-only link).
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	defer origin.Close()

	mgr := job.New(1)
	s := New(mgr, "tok", t.TempDir())
	if _, err := s.Start(); err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	body := []byte(`{"url":"` + origin.URL + `/file.bin","filename":"file.bin"}`)
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
	if resp.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("got %d, want 422 (refuse so the browser download is kept); body=%v", resp.StatusCode, m)
	}
	if !strings.Contains(m["error"].(string), "403") {
		t.Errorf("error should explain the 403, got %v", m["error"])
	}
	if n := len(mgr.Statuses()); n != 0 {
		t.Errorf("no job should be enqueued for an unfetchable URL, got %d", n)
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

func TestShowRequiresTokenAndIsOneShot(t *testing.T) {
	s := New(nil, "tok", t.TempDir())
	// Wrong token: refused, nothing pending.
	rr := httptest.NewRecorder()
	s.handleShow(rr, httptest.NewRequest(http.MethodPost, "/show", nil))
	if rr.Code != http.StatusForbidden || s.ShowPending() {
		t.Fatalf("no token: code=%d pending=%v", rr.Code, s.ShowPending())
	}
	// Web page origin: refused even with the token.
	rr = httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/show", nil)
	req.Header.Set("X-Cascade-Token", "tok")
	req.Header.Set("Origin", "https://example.com")
	s.handleShow(rr, req)
	if rr.Code != http.StatusForbidden || s.ShowPending() {
		t.Fatalf("web origin: code=%d", rr.Code)
	}
	// Local caller with the token: pending exactly once.
	rr = httptest.NewRecorder()
	req = httptest.NewRequest(http.MethodPost, "/show", nil)
	req.Header.Set("X-Cascade-Token", "tok")
	s.handleShow(rr, req)
	if rr.Code != http.StatusOK || !s.ShowPending() || s.ShowPending() {
		t.Fatalf("show: code=%d; ShowPending must be true once then false", rr.Code)
	}
}

// postAdd is a token-authenticated POST /add; returns status and decoded body.
func postAdd(t *testing.T, base string, req addRequest) (int, map[string]any) {
	t.Helper()
	body, _ := json.Marshal(req)
	r, _ := http.NewRequest(http.MethodPost, base+"/add", bytes.NewReader(body))
	r.Header.Set("X-Cascade-Token", "secret-token")
	r.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var got map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&got)
	return resp.StatusCode, got
}

func TestAddSanitisesFilename(t *testing.T) {
	origin := okOrigin(t)
	mgr := job.New(1)
	mgr.SetStartGate(func() bool { return false }) // inspect the queued path, nothing runs
	dir := t.TempDir()
	s := New(mgr, "secret-token", dir)
	addr, err := s.Start()
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	base := "http://" + addr

	cases := []struct{ filename, wantBase string }{
		{"../../evil.bin", "evil.bin"},
		{"..\\..\\evil2.bin", "evil2.bin"},
		{"sub/dir/name.bin", "name.bin"},
		{"..", "f.bin"}, // nothing usable: derive from the URL
		{".", "f.bin"},
		{"/", "f.bin"},
		{"C:evil", "C_evil"},           // drive / NTFS stream separator
		{"report.pdf. ", "report.pdf"}, // Win32 strips trailing dots and spaces
		{"CON", "f.bin"},               // reserved device names
		{"nul.txt", "f.bin"},
		{strings.Repeat("a", 300) + ".tar.gz", strings.Repeat("a", 197) + ".gz"},
	}
	for _, c := range cases {
		code, got := postAdd(t, base, addRequest{URL: origin.URL + "/f.bin", Filename: c.filename})
		if code != http.StatusOK {
			t.Fatalf("%q: status %d (%v)", c.filename, code, got)
		}
		st, ok := mgr.Status(got["id"].(string))
		if !ok {
			t.Fatalf("%q: job missing", c.filename)
		}
		if want := filepath.Join(dir, c.wantBase); st.Out != want {
			t.Fatalf("filename %q: Out = %q, want %q", c.filename, st.Out, want)
		}
		_ = mgr.Remove(st.ID) // so the next case is not deduped onto this job
	}
}
