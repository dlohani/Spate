package download

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// --- helpers -------------------------------------------------------------

func randomBlob(n int) []byte {
	b := make([]byte, n)
	r := rand.New(rand.NewSource(1)) // deterministic
	r.Read(b)
	return b
}

func sha256hex(b []byte) string {
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

// parseRange parses "bytes=start-end" against total. Only the closed form the
// client emits is supported.
func parseRange(h string, total int64) (start, end int64, ok bool) {
	if !strings.HasPrefix(h, "bytes=") {
		return 0, 0, false
	}
	spec := strings.TrimPrefix(h, "bytes=")
	dash := strings.IndexByte(spec, '-')
	if dash < 0 {
		return 0, 0, false
	}
	var err error
	start, err = strconv.ParseInt(spec[:dash], 10, 64)
	if err != nil {
		return 0, 0, false
	}
	end, err = strconv.ParseInt(spec[dash+1:], 10, 64)
	if err != nil || start < 0 || end >= total || start > end {
		return 0, 0, false
	}
	return start, end, true
}

// manualServer serves a blob with configurable range support, ETag, and an
// optional byte budget after which it returns 503 (to simulate a mid-download
// failure that the client must resume from).
type manualServer struct {
	data      []byte
	etag      string
	noRange   bool
	budget    *atomic.Int64 // nil = unlimited
	maxConc   atomic.Int64
	curConc   atomic.Int64
	delay     time.Duration
	slowFrom  int64 // ranges whose start >= slowFrom incur delay (default 0 = all)
	connLimit int64 // if > 0, concurrent range requests beyond this get 503

	// Optional access requirements; when set, requests missing them get 401.
	reqHeaderKey string
	reqHeaderVal string
	reqCookie    string
	reqUser      string
	reqPass      string

	served atomic.Int64 // body bytes written across all range responses
}

func (m *manualServer) authOK(r *http.Request) bool {
	if m.reqHeaderKey != "" && r.Header.Get(m.reqHeaderKey) != m.reqHeaderVal {
		return false
	}
	if m.reqCookie != "" && r.Header.Get("Cookie") != m.reqCookie {
		return false
	}
	if m.reqUser != "" {
		u, p, ok := r.BasicAuth()
		if !ok || u != m.reqUser || p != m.reqPass {
			return false
		}
	}
	return true
}

func (m *manualServer) handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cur := m.curConc.Add(1)
		for {
			old := m.maxConc.Load()
			if cur <= old || m.maxConc.CompareAndSwap(old, cur) {
				break
			}
		}
		defer m.curConc.Add(-1)

		if !m.authOK(r) {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}

		total := int64(len(m.data))
		if m.etag != "" {
			w.Header().Set("ETag", m.etag)
		}
		if !m.noRange {
			w.Header().Set("Accept-Ranges", "bytes")
		}
		if r.Method == http.MethodHead {
			w.Header().Set("Content-Length", strconv.FormatInt(total, 10))
			w.WriteHeader(http.StatusOK)
			return
		}

		rangeHdr := r.Header.Get("Range")
		ifRange := r.Header.Get("If-Range")
		rangeOK := !m.noRange && rangeHdr != "" && (ifRange == "" || ifRange == m.etag)
		if !rangeOK {
			w.Header().Set("Content-Length", strconv.FormatInt(total, 10))
			w.WriteHeader(http.StatusOK)
			w.Write(m.data)
			return
		}

		start, end, ok := parseRange(rangeHdr, total)
		if !ok {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		if m.connLimit > 0 && cur > m.connLimit {
			w.WriteHeader(http.StatusServiceUnavailable) // "one connection per IP" host
			return
		}
		if m.delay > 0 && start >= m.slowFrom {
			time.Sleep(m.delay)
		}
		reqLen := end - start + 1
		allowed := reqLen
		if m.budget != nil {
			rem := m.budget.Add(-reqLen)
			if rem < 0 {
				allowed = reqLen + rem
				if allowed <= 0 {
					w.WriteHeader(http.StatusServiceUnavailable)
					return
				}
			}
		}
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, total))
		w.Header().Set("Content-Length", strconv.FormatInt(allowed, 10))
		w.WriteHeader(http.StatusPartialContent)
		w.Write(m.data[start : start+allowed])
		m.served.Add(allowed)
	}
}

// --- tests ---------------------------------------------------------------

func TestPlanSegments(t *testing.T) {
	cases := []struct {
		total   int64
		conns   int
		minSeg  int64
		wantN   int
		wantSum int64
	}{
		{total: 1000, conns: 4, minSeg: 100, wantN: 4, wantSum: 1000},
		{total: 1001, conns: 4, minSeg: 100, wantN: 4, wantSum: 1001}, // uneven
		{total: 150, conns: 8, minSeg: 100, wantN: 1, wantSum: 150},   // minSeg caps N
		{total: 1, conns: 8, minSeg: 100, wantN: 1, wantSum: 1},
		{total: 0, conns: 8, minSeg: 100, wantN: 1, wantSum: 0}, // empty file
	}
	for _, c := range cases {
		segs := PlanSegments(c.total, c.conns, c.minSeg)
		if len(segs) != c.wantN {
			t.Errorf("total=%d conns=%d: got %d segments, want %d", c.total, c.conns, len(segs), c.wantN)
		}
		var sum int64
		var prevEnd int64 = -1
		for _, s := range segs {
			sum += s.Length()
			if s.Length() > 0 && s.Start != prevEnd+1 {
				t.Errorf("total=%d: segment %d not contiguous: start=%d prevEnd=%d", c.total, s.Index, s.Start, prevEnd)
			}
			if s.Length() > 0 {
				prevEnd = s.End
			}
		}
		if sum != c.wantSum {
			t.Errorf("total=%d: segment lengths sum to %d, want %d", c.total, sum, c.wantSum)
		}
	}
}

func TestHappyPathMultiConn(t *testing.T) {
	data := randomBlob(5 << 20) // 5 MiB
	m := &manualServer{data: data, etag: `"v1"`}
	srv := httptest.NewServer(m.handler())
	defer srv.Close()

	out := filepath.Join(t.TempDir(), "file.bin")
	d := New(srv.URL, out, Options{Conns: 8, MinSegment: 256 << 10, SHA256: sha256hex(data)})
	if err := d.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}

	got, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, data) {
		t.Fatalf("downloaded file differs from source (len got=%d want=%d)", len(got), len(data))
	}
	if _, err := os.Stat(out + controlExt); !os.IsNotExist(err) {
		t.Errorf("sidecar not removed after success: %v", err)
	}
	if m.maxConc.Load() < 2 {
		t.Errorf("expected concurrent connections, max observed = %d", m.maxConc.Load())
	}
}

func TestResumeAfterFailure(t *testing.T) {
	data := randomBlob(4 << 20) // 4 MiB
	budget := &atomic.Int64{}
	budget.Store(int64(len(data)) / 2) // only half will transfer before 503s
	m := &manualServer{data: data, etag: `"v1"`, budget: budget}
	srv := httptest.NewServer(m.handler())
	defer srv.Close()

	out := filepath.Join(t.TempDir(), "file.bin")

	// First run: expected to fail partway (retries exhausted on 503).
	d1 := New(srv.URL, out, Options{Conns: 4, MinSegment: 256 << 10, Retries: 1, Resume: true})
	if err := d1.Run(context.Background()); err == nil {
		t.Fatal("first run: expected failure from exhausted budget, got nil")
	}
	ctrl, err := LoadControl(out)
	if err != nil || ctrl == nil {
		t.Fatalf("expected resume sidecar after failure: ctrl=%v err=%v", ctrl, err)
	}
	partial := ctrl.BytesDone()
	if partial <= 0 || partial >= int64(len(data)) {
		t.Fatalf("expected partial progress, got %d of %d", partial, len(data))
	}

	// Lift the budget and resume.
	budget.Store(1 << 62)
	d2 := New(srv.URL, out, Options{Conns: 4, MinSegment: 256 << 10, Retries: 3, Resume: true, SHA256: sha256hex(data)})
	if err := d2.Run(context.Background()); err != nil {
		t.Fatalf("resume run: %v", err)
	}
	got, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, data) {
		t.Fatal("resumed file differs from source")
	}
}

func TestValidatorChangedRestartsClean(t *testing.T) {
	data1 := randomBlob(3 << 20)
	budget := &atomic.Int64{}
	budget.Store(int64(len(data1)) / 3)
	m := &manualServer{data: data1, etag: `"v1"`, budget: budget}
	srv := httptest.NewServer(m.handler())
	defer srv.Close()

	out := filepath.Join(t.TempDir(), "file.bin")
	d1 := New(srv.URL, out, Options{Conns: 4, MinSegment: 256 << 10, Retries: 1, Resume: true})
	if err := d1.Run(context.Background()); err == nil {
		t.Fatal("first run: expected failure")
	}
	if ctrl, _ := LoadControl(out); ctrl == nil {
		t.Fatal("expected sidecar after partial run")
	}

	// Upstream file changes: new content, same size, new validator.
	data2 := randomBlob(3 << 20)
	data2[0] ^= 0xFF // ensure different content even with same seed-derived bytes
	m.data = data2
	m.etag = `"v2"`
	budget.Store(1 << 62)

	d2 := New(srv.URL, out, Options{Conns: 4, MinSegment: 256 << 10, Retries: 3, Resume: true, SHA256: sha256hex(data2)})
	if err := d2.Run(context.Background()); err != nil {
		t.Fatalf("restart run: %v", err)
	}
	got, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, data2) {
		t.Fatal("after validator change, file should match new content, not a stale merge")
	}
}

func TestNoRangeFallback(t *testing.T) {
	data := randomBlob(2 << 20)
	m := &manualServer{data: data, noRange: true}
	srv := httptest.NewServer(m.handler())
	defer srv.Close()

	out := filepath.Join(t.TempDir(), "file.bin")
	d := New(srv.URL, out, Options{Conns: 8, SHA256: sha256hex(data)})
	if err := d.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	got, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, data) {
		t.Fatal("single-connection fallback produced wrong content")
	}
}

func TestNextWorkStealsLargestTail(t *testing.T) {
	const total = int64(100 << 20)
	segs := PlanSegments(total, 2, 1<<20) // two 50 MiB segments
	c := NewControl("out.bin", "http://x", total, `"v1"`, segs)

	// Both segments are owned by workers; seg0 nearly done, seg1 untouched.
	c.assigned[0] = true
	c.assigned[1] = true
	c.Segments[0].Done = c.Segments[0].Length() - (1 << 10) // 1 KiB left
	oldEnd := c.Segments[1].End

	idx, ok := c.nextWork(8 << 20)
	if !ok {
		t.Fatal("expected a steal, got none")
	}
	if idx != 2 {
		t.Fatalf("expected new tail segment index 2, got %d", idx)
	}
	victim := c.Segments[1] // largest remaining tail must be the victim
	tail := c.Segments[2]
	if victim.End >= oldEnd {
		t.Errorf("victim end not reduced: got %d, was %d", victim.End, oldEnd)
	}
	if tail.Start != victim.End+1 || tail.End != oldEnd {
		t.Errorf("tail bounds wrong: tail=%+v victim.End=%d oldEnd=%d", tail, victim.End, oldEnd)
	}
	if !c.assigned[2] {
		t.Error("stolen tail should be marked assigned")
	}
	if c.Splits() != 1 {
		t.Errorf("expected 1 split, got %d", c.Splits())
	}

	// A tail below the threshold must not be split.
	if _, ok := c.nextWork(1 << 62); ok {
		t.Error("did not expect a steal when no tail meets the threshold")
	}
}

func TestWorkStealingCompletesSlowSegment(t *testing.T) {
	data := randomBlob(8 << 20) // 8 MiB
	// Make the second half slow so the worker on the first half finishes early
	// and steals the laggard's tail.
	m := &manualServer{data: data, etag: `"v1"`, delay: 80 * time.Millisecond, slowFrom: 4 << 20}
	srv := httptest.NewServer(m.handler())
	defer srv.Close()

	out := filepath.Join(t.TempDir(), "file.bin")
	d := New(srv.URL, out, Options{
		Conns:             2,
		MinSegment:        4 << 20,   // two initial 4 MiB segments
		WindowSize:        512 << 10, // small windows so steals can take effect
		StealMinRemaining: 1 << 20,
		SHA256:            sha256hex(data),
	})
	if err := d.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	got, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, data) {
		t.Fatal("work-stealing produced wrong content")
	}
	if d.Splits() < 1 {
		t.Errorf("expected at least one work-steal split, got %d", d.Splits())
	}
}

func TestAuthHeadersAndCookie(t *testing.T) {
	data := randomBlob(2 << 20)
	m := &manualServer{
		data: data, etag: `"v1"`,
		reqHeaderKey: "X-Token", reqHeaderVal: "secret",
		reqCookie: "sid=abc",
		reqUser:   "alice", reqPass: "pw",
	}
	srv := httptest.NewServer(m.handler())
	defer srv.Close()
	out := filepath.Join(t.TempDir(), "file.bin")

	// Without credentials: must fail (401 on probe).
	bad := New(srv.URL, out, Options{Conns: 2})
	if err := bad.Run(context.Background()); err == nil {
		t.Fatal("expected failure without credentials")
	}

	// With all credentials supplied: succeeds.
	good := New(srv.URL, out, Options{
		Conns:         4,
		MinSegment:    256 << 10,
		Headers:       map[string]string{"X-Token": "secret"},
		Cookie:        "sid=abc",
		BasicUser:     "alice",
		BasicPassword: "pw",
		SHA256:        sha256hex(data),
	})
	if err := good.Run(context.Background()); err != nil {
		t.Fatalf("Run with credentials: %v", err)
	}
	got, _ := os.ReadFile(out)
	if !bytes.Equal(got, data) {
		t.Fatal("authenticated download produced wrong content")
	}
}

func TestURLRefreshOnExpiry(t *testing.T) {
	data := randomBlob(4 << 20)
	total := int64(len(data))
	half := total / 2

	// The second half of the file requires the refreshed token "B"; requests
	// for it with the stale token "A" get 403, simulating an expired signed URL.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok := r.URL.Query().Get("t")
		w.Header().Set("Accept-Ranges", "bytes")
		w.Header().Set("ETag", `"v1"`)
		if r.Method == http.MethodHead {
			if tok == "" {
				w.WriteHeader(http.StatusForbidden)
				return
			}
			w.Header().Set("Content-Length", strconv.FormatInt(total, 10))
			w.WriteHeader(http.StatusOK)
			return
		}
		start, end, ok := parseRange(r.Header.Get("Range"), total)
		if !ok {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		if start >= half && tok != "B" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		if start < half && tok == "" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, total))
		w.Header().Set("Content-Length", strconv.FormatInt(end-start+1, 10))
		w.WriteHeader(http.StatusPartialContent)
		w.Write(data[start : end+1])
	}))
	defer srv.Close()

	out := filepath.Join(t.TempDir(), "file.bin")
	var refreshCalls atomic.Int64
	d := New(srv.URL+"?t=A", out, Options{
		Conns:      4,
		MinSegment: 256 << 10,
		SHA256:     sha256hex(data),
		RefreshURL: func(ctx context.Context, old string) (string, error) {
			refreshCalls.Add(1)
			return srv.URL + "?t=B", nil
		},
	})
	if err := d.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	got, _ := os.ReadFile(out)
	if !bytes.Equal(got, data) {
		t.Fatal("refresh download produced wrong content")
	}
	if refreshCalls.Load() == 0 {
		t.Error("expected RefreshURL to be called")
	}
	if !strings.Contains(d.currentURL(), "t=B") {
		t.Errorf("expected URL to be refreshed to t=B, got %s", d.currentURL())
	}
}

func TestIsTransientClassification(t *testing.T) {
	transient := []error{
		&netError{errors.New("local error: tls: bad record MAC")},
		&netError{io.ErrClosedPipe},
		&httpStatusError{code: 503, status: "503"},
		io.ErrUnexpectedEOF,
		errURLRefreshed,
		fmt.Errorf("wrapped: %w", &netError{errors.New("read: connection reset")}),
	}
	for _, e := range transient {
		if !isTransient(e) {
			t.Errorf("expected transient: %v", e)
		}
	}
	fatal := []error{
		nil,
		errors.New("some logical error"),
		fmt.Errorf("segment 3: unexpected status 404 Not Found"),
	}
	for _, e := range fatal {
		if isTransient(e) {
			t.Errorf("expected NOT transient: %v", e)
		}
	}
}

func TestDeriveFilenameAddsExtension(t *testing.T) {
	cases := []struct {
		url, suggested, ctype, want string
	}{
		{"http://x/file.bin", "", "", "file.bin"},
		{"http://x/report", "", "application/pdf", "report.pdf"},
		{"http://x/data", "", "application/zip", "data.zip"},
		{"http://x/thing", "", "application/octet-stream", "thing"},
		{"http://x/", "", "", "download.bin"},
		{"http://x/whatever", "server-name.txt", "application/pdf", "server-name.txt"},
	}
	for _, c := range cases {
		got := deriveFilename(c.url, c.suggested, c.ctype)
		if got != c.want {
			t.Errorf("deriveFilename(%q,%q,%q) = %q, want %q", c.url, c.suggested, c.ctype, got, c.want)
		}
	}
}

func TestExtractZipAfterDownload(t *testing.T) {
	// Build a small zip in memory.
	var zbuf bytes.Buffer
	zw := zip.NewWriter(&zbuf)
	files := map[string]string{"a.txt": "hello", "dir/b.txt": "world"}
	for name, content := range files {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		w.Write([]byte(content))
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	data := zbuf.Bytes()

	m := &manualServer{data: data, etag: `"z1"`}
	srv := httptest.NewServer(m.handler())
	defer srv.Close()

	dir := t.TempDir()
	out := filepath.Join(dir, "archive.zip")
	dest := filepath.Join(dir, "unpacked")
	d := New(srv.URL, out, Options{Conns: 2, ExtractTo: dest, SHA256: sha256hex(data)})
	if err := d.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	for name, content := range files {
		got, err := os.ReadFile(filepath.Join(dest, name))
		if err != nil {
			t.Fatalf("extracted %s: %v", name, err)
		}
		if string(got) != content {
			t.Errorf("extracted %s = %q, want %q", name, got, content)
		}
	}
}

func TestExtractZipRejectsTraversal(t *testing.T) {
	dir := t.TempDir()
	zipPath := filepath.Join(dir, "evil.zip")
	f, err := os.Create(zipPath)
	if err != nil {
		t.Fatal(err)
	}
	zw := zip.NewWriter(f)
	w, _ := zw.Create("../escape.txt")
	w.Write([]byte("pwned"))
	zw.Close()
	f.Close()

	if err := extractZip(zipPath, filepath.Join(dir, "dest")); err == nil {
		t.Fatal("expected zip-slip traversal to be rejected")
	}
}

func TestGateBlocksThenResumes(t *testing.T) {
	// Initial gate closed: Run must fail immediately with a *GateError.
	data := randomBlob(2 << 20)
	m := &manualServer{data: data, etag: `"v1"`}
	srv := httptest.NewServer(m.handler())
	defer srv.Close()
	out := filepath.Join(t.TempDir(), "file.bin")

	blocked := New(srv.URL, out, Options{
		Conns: 2,
		Gate:  func() (bool, string) { return false, "test: closed" },
	})
	err := blocked.Run(context.Background())
	var ge *GateError
	if !errors.As(err, &ge) {
		t.Fatalf("expected *GateError, got %v", err)
	}

	// Gate that closes after the first (initial) check, cancelling mid-download.
	data2 := randomBlob(4 << 20)
	m2 := &manualServer{data: data2, etag: `"v2"`, delay: 20 * time.Millisecond}
	srv2 := httptest.NewServer(m2.handler())
	defer srv2.Close()
	out2 := filepath.Join(t.TempDir(), "file2.bin")

	var calls atomic.Int64
	d := New(srv2.URL, out2, Options{
		Conns:            4,
		MinSegment:       256 << 10,
		WindowSize:       256 << 10,
		GatePollInterval: 10 * time.Millisecond,
		Resume:           true,
		Gate: func() (bool, string) {
			if calls.Add(1) <= 1 {
				return true, "" // initial check passes
			}
			return false, "test: closed mid-download"
		},
	})
	if err := d.Run(context.Background()); !errors.As(err, &ge) {
		t.Fatalf("expected *GateError mid-download, got %v", err)
	}
	if ctrl, _ := LoadControl(out2); ctrl == nil {
		t.Fatal("expected resumable sidecar after gate closed")
	}

	// Reopen the gate and resume to completion.
	d2 := New(srv2.URL, out2, Options{
		Conns: 4, MinSegment: 256 << 10, WindowSize: 256 << 10, Resume: true,
		SHA256: sha256hex(data2),
		Gate:   func() (bool, string) { return true, "" },
	})
	if err := d2.Run(context.Background()); err != nil {
		t.Fatalf("resume after gate reopened: %v", err)
	}
	got, _ := os.ReadFile(out2)
	if !bytes.Equal(got, data2) {
		t.Fatal("content mismatch after gate resume")
	}
}

func TestAdaptsToSingleConnectionHost(t *testing.T) {
	// A free-tier style host: one range request at a time, 503 for any extra.
	data := randomBlob(3 << 20)
	m := &manualServer{data: data, etag: `"v1"`, connLimit: 1, delay: 5 * time.Millisecond}
	srv := httptest.NewServer(m.handler())
	defer srv.Close()

	out := filepath.Join(t.TempDir(), "file.bin")
	d := New(srv.URL, out, Options{
		Conns:      4, // we ask for 4; the host tolerates 1
		MinSegment: 256 << 10,
		WindowSize: 256 << 10,
		SHA256:     sha256hex(data),
	})
	if err := d.Run(context.Background()); err != nil {
		t.Fatalf("Run against a 1-connection host: %v", err)
	}
	got, _ := os.ReadFile(out)
	if !bytes.Equal(got, data) {
		t.Fatal("content mismatch on single-connection host")
	}
	if lim := d.conns.limit(); lim != 1 {
		t.Errorf("connection limit should have adapted to 1, got %d", lim)
	}
}

func TestCancellationLeavesResumableState(t *testing.T) {
	data := randomBlob(8 << 20)
	m := &manualServer{data: data, etag: `"v1"`, delay: 40 * time.Millisecond}
	srv := httptest.NewServer(m.handler())
	defer srv.Close()

	out := filepath.Join(t.TempDir(), "file.bin")
	ctx, cancel := context.WithCancel(context.Background())
	// Small windows so each segment needs several delayed requests, keeping the
	// transfer in flight long enough to be cancelled mid-download.
	d := New(srv.URL, out, Options{Conns: 4, MinSegment: 256 << 10, WindowSize: 256 << 10, Retries: 2, Resume: true})

	var wg sync.WaitGroup
	wg.Add(1)
	var runErr error
	go func() { defer wg.Done(); runErr = d.Run(ctx) }()
	time.Sleep(60 * time.Millisecond)
	cancel()
	wg.Wait()

	if runErr == nil {
		t.Fatal("expected non-nil error after cancellation")
	}
	if ctrl, _ := LoadControl(out); ctrl == nil {
		t.Fatal("expected resumable sidecar after cancellation")
	}
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

func TestWritesPartThenRenames(t *testing.T) {
	data := randomBlob(2 << 20)
	m := &manualServer{data: data, etag: `"v1"`, delay: 150 * time.Millisecond}
	srv := httptest.NewServer(m.handler())
	defer srv.Close()
	out := filepath.Join(t.TempDir(), "file.bin")
	if PartPath(out) != out+".part" {
		t.Fatalf("PartPath = %q", PartPath(out))
	}
	d := New(srv.URL, out, Options{Conns: 2, MinSegment: 256 << 10})
	done := make(chan error, 1)
	go func() { done <- d.Run(context.Background()) }()
	deadline := time.Now().Add(5 * time.Second)
	for !exists(PartPath(out)) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if !exists(PartPath(out)) {
		t.Fatal("no .part file appeared while downloading")
	}
	if exists(out) {
		t.Fatal("final path exists while the download is in progress")
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if exists(PartPath(out)) || exists(controlPath(out)) {
		t.Fatal(".part or sidecar left behind after completion")
	}
	got, _ := os.ReadFile(out)
	if !bytes.Equal(got, data) {
		t.Fatal("final file differs")
	}
	if d.Output() != out {
		t.Fatalf("Output = %q", d.Output())
	}
}

func TestResumeWithoutPartStartsFresh(t *testing.T) {
	data := randomBlob(2 << 20)
	budget := &atomic.Int64{}
	budget.Store(int64(len(data)) / 2)
	m := &manualServer{data: data, etag: `"v1"`, budget: budget}
	srv := httptest.NewServer(m.handler())
	defer srv.Close()
	out := filepath.Join(t.TempDir(), "file.bin")
	d1 := New(srv.URL, out, Options{Conns: 2, MinSegment: 256 << 10, Retries: 1, Resume: true})
	if err := d1.Run(context.Background()); err == nil {
		t.Fatal("expected the budgeted run to fail")
	}
	if !exists(PartPath(out)) || !exists(controlPath(out)) {
		t.Fatal("expected .part and sidecar after failure")
	}
	os.Remove(PartPath(out)) // the user cleaned up while the app was closed
	budget.Store(1 << 62)
	d2 := New(srv.URL, out, Options{Conns: 2, MinSegment: 256 << 10, Resume: true, SHA256: sha256hex(data)})
	if err := d2.Run(context.Background()); err != nil {
		t.Fatalf("fresh start after missing part: %v", err)
	}
	got, _ := os.ReadFile(out)
	if !bytes.Equal(got, data) {
		t.Fatal("file differs")
	}
}

func TestCompleteDoesNotOverwriteExisting(t *testing.T) {
	data := randomBlob(1 << 20)
	m := &manualServer{data: data, etag: `"v1"`}
	srv := httptest.NewServer(m.handler())
	defer srv.Close()
	dir := t.TempDir()
	out := filepath.Join(dir, "file.bin")
	if err := os.WriteFile(out, []byte("keep me"), 0o644); err != nil {
		t.Fatal(err)
	}
	d := New(srv.URL, out, Options{Conns: 2, MinSegment: 256 << 10})
	if err := d.Run(context.Background()); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(out); string(b) != "keep me" {
		t.Fatal("existing file was overwritten")
	}
	want := filepath.Join(dir, "file (1).bin")
	if d.Output() != want {
		t.Fatalf("Output = %q, want %q", d.Output(), want)
	}
	if got, _ := os.ReadFile(want); !bytes.Equal(got, data) {
		t.Fatal("renamed file differs")
	}
}

func TestLegacyPartialIsAdopted(t *testing.T) {
	data := randomBlob(2 << 20)
	budget := &atomic.Int64{}
	budget.Store(int64(len(data)) / 2)
	m := &manualServer{data: data, etag: `"v1"`, budget: budget}
	srv := httptest.NewServer(m.handler())
	defer srv.Close()
	out := filepath.Join(t.TempDir(), "file.bin")
	d1 := New(srv.URL, out, Options{Conns: 2, MinSegment: 256 << 10, Retries: 1, Resume: true})
	if err := d1.Run(context.Background()); err == nil {
		t.Fatal("expected the budgeted run to fail")
	}
	// Old layout: the data lived at the final path, sidecar beside it.
	if err := os.Rename(PartPath(out), out); err != nil {
		t.Fatal(err)
	}
	budget.Store(1 << 62)
	m.served.Store(0)
	d2 := New(srv.URL, out, Options{Conns: 2, MinSegment: 256 << 10, Resume: true, SHA256: sha256hex(data)})
	if err := d2.Run(context.Background()); err != nil {
		t.Fatalf("resume from legacy layout: %v", err)
	}
	if served := m.served.Load(); served >= int64(len(data)) {
		t.Fatalf("legacy partial was not reused: served %d of %d", served, len(data))
	}
	if exists(PartPath(out)) {
		t.Fatal(".part left behind")
	}
}
