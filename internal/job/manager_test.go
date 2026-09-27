package job

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
	"testing"
	"time"

	"cascade/internal/download"
)

func blob(n int) []byte {
	b := make([]byte, n)
	rand.New(rand.NewSource(7)).Read(b)
	return b
}

func sha(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }

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
	if start, err = strconv.ParseInt(spec[:dash], 10, 64); err != nil {
		return 0, 0, false
	}
	if end, err = strconv.ParseInt(spec[dash+1:], 10, 64); err != nil || end >= total || start > end {
		return 0, 0, false
	}
	return start, end, true
}

// rangeServer serves data with byte-range support, an optional per-request
// delay, and optional recording of request paths and times.
func rangeServer(data []byte, delay time.Duration, mu *sync.Mutex, paths *[]string, firstReq *time.Time) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if mu != nil {
			mu.Lock()
			if paths != nil {
				*paths = append(*paths, r.URL.Path)
			}
			if firstReq != nil && firstReq.IsZero() {
				*firstReq = time.Now()
			}
			mu.Unlock()
		}
		total := int64(len(data))
		w.Header().Set("Accept-Ranges", "bytes")
		w.Header().Set("ETag", `"v1"`)
		if r.Method == http.MethodHead {
			w.Header().Set("Content-Length", strconv.FormatInt(total, 10))
			w.WriteHeader(http.StatusOK)
			return
		}
		start, end, ok := parseRange(r.Header.Get("Range"), total)
		if !ok {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		if delay > 0 {
			time.Sleep(delay)
		}
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, total))
		w.Header().Set("Content-Length", strconv.FormatInt(end-start+1, 10))
		w.WriteHeader(http.StatusPartialContent)
		w.Write(data[start : end+1])
	}
}

func TestManagerRunsAllJobs(t *testing.T) {
	data := blob(1 << 20)
	srv := httptest.NewServer(rangeServer(data, 0, nil, nil, nil))
	defer srv.Close()
	dir := t.TempDir()

	m := New(2)
	var ids []string
	for i := 0; i < 4; i++ {
		out := filepath.Join(dir, fmt.Sprintf("f%d.bin", i))
		id, err := m.Add(Spec{URL: srv.URL + fmt.Sprintf("/f%d", i), Out: out,
			Options: download.Options{Conns: 4, MinSegment: 128 << 10, SHA256: sha(data)}})
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	if err := m.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	for i, id := range ids {
		st, _ := m.Status(id)
		if st.State != Done {
			t.Errorf("job %s state = %s, want done (err=%v)", id, st.State, st.Err)
		}
		got, _ := os.ReadFile(filepath.Join(dir, fmt.Sprintf("f%d.bin", i)))
		if !bytes.Equal(got, data) {
			t.Errorf("job %s content mismatch", id)
		}
	}
}

func TestPriorityOrderWithSingleSlot(t *testing.T) {
	data := blob(256 << 10)
	var mu sync.Mutex
	var paths []string
	srv := httptest.NewServer(rangeServer(data, 0, &mu, &paths, nil))
	defer srv.Close()
	dir := t.TempDir()

	m := New(1) // one at a time, so priority decides order
	specs := []struct {
		path string
		prio int
	}{
		{"/low", 1},
		{"/high", 3},
		{"/mid", 2},
	}
	for _, s := range specs {
		if _, err := m.Add(Spec{URL: srv.URL + s.path, Out: filepath.Join(dir, s.path[1:]+".bin"),
			Priority: s.prio, Options: download.Options{Conns: 2, MinSegment: 128 << 10}}); err != nil {
			t.Fatal(err)
		}
	}
	if err := m.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}

	// First-seen order of paths should be high, mid, low.
	seen := []string{}
	for _, p := range paths {
		if len(seen) == 0 || seen[len(seen)-1] != p {
			dup := false
			for _, s := range seen {
				if s == p {
					dup = true
					break
				}
			}
			if !dup {
				seen = append(seen, p)
			}
		}
	}
	want := []string{"/high", "/mid", "/low"}
	if len(seen) != 3 || seen[0] != want[0] || seen[1] != want[1] || seen[2] != want[2] {
		t.Errorf("start order = %v, want %v", seen, want)
	}
}

func TestScheduledStartDelaysJob(t *testing.T) {
	data := blob(256 << 10)
	var mu sync.Mutex
	var firstReq time.Time
	srv := httptest.NewServer(rangeServer(data, 0, &mu, nil, &firstReq))
	defer srv.Close()

	startAt := time.Now().Add(250 * time.Millisecond)
	m := New(1)
	if _, err := m.Add(Spec{URL: srv.URL + "/f", Out: filepath.Join(t.TempDir(), "f.bin"),
		StartAt: startAt, Options: download.Options{Conns: 2}}); err != nil {
		t.Fatal(err)
	}
	if err := m.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	mu.Lock()
	fr := firstReq
	mu.Unlock()
	if fr.Before(startAt.Add(-30 * time.Millisecond)) {
		t.Errorf("job started at %v, before scheduled %v", fr, startAt)
	}
}

func TestPauseAndResume(t *testing.T) {
	data := blob(4 << 20)
	srv := httptest.NewServer(rangeServer(data, 25*time.Millisecond, nil, nil, nil))
	defer srv.Close()
	out := filepath.Join(t.TempDir(), "f.bin")

	m := New(1)
	id, err := m.Add(Spec{URL: srv.URL + "/f", Out: out, Options: download.Options{
		Conns: 2, MinSegment: 256 << 10, WindowSize: 256 << 10, SHA256: sha(data),
	}})
	if err != nil {
		t.Fatal(err)
	}

	runErr := make(chan error, 1)
	go func() { runErr <- m.Run(context.Background()) }()

	// Wait until it is running and has made some progress.
	waitFor(t, 3*time.Second, func() bool {
		st, _ := m.Status(id)
		return st.State == Running && st.Bytes > 0
	})
	if err := m.Pause(id); err != nil {
		t.Fatalf("Pause: %v", err)
	}
	waitFor(t, 3*time.Second, func() bool {
		st, _ := m.Status(id)
		return st.State == Paused
	})
	st, _ := m.Status(id)
	if st.Bytes >= int64(len(data)) {
		t.Fatalf("paused after full download (%d bytes); test too slow", st.Bytes)
	}

	if err := m.Resume(id); err != nil {
		t.Fatalf("Resume: %v", err)
	}
	if err := <-runErr; err != nil {
		t.Fatalf("Run after resume: %v", err)
	}
	final, _ := m.Status(id)
	if final.State != Done {
		t.Fatalf("final state = %s (err=%v)", final.State, final.Err)
	}
	got, _ := os.ReadFile(out)
	if !bytes.Equal(got, data) {
		t.Fatal("content mismatch after pause/resume")
	}
}

func waitFor(t *testing.T, timeout time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("condition not met within timeout")
}
