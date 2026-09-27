package download

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
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
	data    []byte
	etag    string
	noRange bool
	budget  *atomic.Int64 // nil = unlimited
	maxConc atomic.Int64
	curConc atomic.Int64
	delay   time.Duration
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
		if m.delay > 0 {
			time.Sleep(m.delay)
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

func TestCancellationLeavesResumableState(t *testing.T) {
	data := randomBlob(4 << 20)
	m := &manualServer{data: data, etag: `"v1"`, delay: 40 * time.Millisecond}
	srv := httptest.NewServer(m.handler())
	defer srv.Close()

	out := filepath.Join(t.TempDir(), "file.bin")
	ctx, cancel := context.WithCancel(context.Background())
	d := New(srv.URL, out, Options{Conns: 4, MinSegment: 256 << 10, Retries: 2, Resume: true})

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
