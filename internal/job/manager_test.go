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

	"spate/internal/download"
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

func TestCancelPendingAndClearFinished(t *testing.T) {
	data := blob(256 << 10)
	srv := httptest.NewServer(rangeServer(data, 0, nil, nil, nil))
	defer srv.Close()
	dir := t.TempDir()

	m := New(1) // one slot, so later jobs stay pending
	var ids []string
	for i := 0; i < 3; i++ {
		id, _ := m.Add(Spec{URL: srv.URL + fmt.Sprintf("/f%d", i),
			Out:     filepath.Join(dir, fmt.Sprintf("f%d.bin", i)),
			Options: download.Options{Conns: 2, MinSegment: 64 << 10}})
		ids = append(ids, id)
	}
	// Cancel a job before Run drains the queue.
	if err := m.Cancel(ids[2]); err != nil {
		t.Fatalf("Cancel: %v", err)
	}
	if st, _ := m.Status(ids[2]); st.State != Cancelled {
		t.Fatalf("job2 state = %s, want cancelled", st.State)
	}

	if err := m.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	// After Run: job0/job1 done, job2 cancelled -> 3 terminal jobs.
	if got := len(m.Statuses()); got != 3 {
		t.Fatalf("expected 3 jobs, got %d", got)
	}
	removed := m.ClearFinished()
	if removed != 3 {
		t.Errorf("ClearFinished removed %d, want 3", removed)
	}
	if got := len(m.Statuses()); got != 0 {
		t.Errorf("after clear, %d jobs remain, want 0", got)
	}
}

func TestCancelRunningJob(t *testing.T) {
	data := blob(4 << 20)
	srv := httptest.NewServer(rangeServer(data, 25*time.Millisecond, nil, nil, nil))
	defer srv.Close()
	out := filepath.Join(t.TempDir(), "f.bin")

	m := New(1)
	id, _ := m.Add(Spec{URL: srv.URL + "/f", Out: out,
		Options: download.Options{Conns: 2, MinSegment: 256 << 10, WindowSize: 256 << 10}})

	runErr := make(chan error, 1)
	go func() { runErr <- m.Run(context.Background()) }()

	waitFor(t, 3*time.Second, func() bool {
		st, _ := m.Status(id)
		return st.State == Running && st.Bytes > 0
	})
	if err := m.Cancel(id); err != nil {
		t.Fatalf("Cancel: %v", err)
	}
	// Run should return once the cancelled job becomes terminal.
	select {
	case err := <-runErr:
		if err != nil {
			t.Fatalf("Run returned error: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return after cancel")
	}
	if st, _ := m.Status(id); st.State != Cancelled {
		t.Fatalf("final state = %s, want cancelled", st.State)
	}
}

func TestRemoveJob(t *testing.T) {
	data := blob(128 << 10)
	srv := httptest.NewServer(rangeServer(data, 0, nil, nil, nil))
	defer srv.Close()
	m := New(1)
	id, _ := m.Add(Spec{URL: srv.URL + "/f", Out: filepath.Join(t.TempDir(), "f.bin"),
		Options: download.Options{Conns: 1}})
	if err := m.Remove(id); err != nil {
		t.Fatalf("Remove: %v", err)
	}
	if _, ok := m.Status(id); ok {
		t.Fatal("job still present after Remove")
	}
}

func TestStartGateAndStartNow(t *testing.T) {
	data := blob(128 << 10)
	srv := httptest.NewServer(rangeServer(data, 0, nil, nil, nil))
	defer srv.Close()
	dir := t.TempDir()

	m := New(2)
	open := false
	m.SetStartGate(func() bool { return open })
	id1, _ := m.Add(Spec{URL: srv.URL + "/a", Out: filepath.Join(dir, "a.bin"), Options: download.Options{Conns: 1}})
	id2, _ := m.Add(Spec{URL: srv.URL + "/b", Out: filepath.Join(dir, "b.bin"), Options: download.Options{Conns: 1},
		StartAt: time.Now().Add(time.Hour)})

	runErr := make(chan error, 1)
	go func() { runErr <- m.Run(context.Background()) }()

	// Gate closed: nothing starts.
	time.Sleep(300 * time.Millisecond)
	if st, _ := m.Status(id1); st.State != Pending {
		t.Fatalf("job should wait for the download window, state=%s", st.State)
	}
	// Open the gate: job1 runs; job2 is scheduled an hour out.
	open = true
	m.SetStartGate(func() bool { return open })
	waitFor(t, 5*time.Second, func() bool { st, _ := m.Status(id1); return st.State == Done })
	if st, _ := m.Status(id2); st.State != Pending || st.StartAt.IsZero() {
		t.Fatalf("job2 should still be scheduled: %+v", st)
	}
	// Start now: the schedule is dropped and it completes.
	if err := m.StartNow(id2); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-runErr:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not finish after StartNow")
	}
	if st, _ := m.Status(id2); st.State != Done {
		t.Fatalf("job2 state = %s", st.State)
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

func TestSetMaxConcurrentAppliesLive(t *testing.T) {
	data := blob(2 << 20)
	srv := httptest.NewServer(rangeServer(data, 20*time.Millisecond, nil, nil, nil))
	defer srv.Close()
	dir := t.TempDir()

	m := New(1)
	ids := make([]string, 3)
	for i := range ids {
		id, err := m.Add(Spec{URL: srv.URL + "/f", Out: filepath.Join(dir, fmt.Sprintf("f%d.bin", i)), Options: download.Options{
			Conns: 1, MinSegment: 256 << 10, WindowSize: 256 << 10,
		}})
		if err != nil {
			t.Fatal(err)
		}
		ids[i] = id
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = m.Serve(ctx) }()

	running := func() int {
		n := 0
		for _, id := range ids {
			if st, _ := m.Status(id); st.State == Running {
				n++
			}
		}
		return n
	}
	waitFor(t, 3*time.Second, func() bool { return running() == 1 })
	m.SetMaxConcurrent(3)
	waitFor(t, 3*time.Second, func() bool { return running() == 3 })
}

func TestDiscardDeletesPartialAndClearFinishedDropsCancelled(t *testing.T) {
	data := blob(4 << 20)
	srv := httptest.NewServer(rangeServer(data, 25*time.Millisecond, nil, nil, nil))
	defer srv.Close()
	dir := t.TempDir()
	opts := download.Options{Conns: 2, MinSegment: 256 << 10, WindowSize: 256 << 10}

	m := New(2)
	a, _ := m.Add(Spec{URL: srv.URL + "/a", Out: filepath.Join(dir, "a.bin"), Options: opts})
	b, _ := m.Add(Spec{URL: srv.URL + "/b", Out: filepath.Join(dir, "b.bin"), Options: opts})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = m.Serve(ctx) }()

	progressing := func(id string) bool { st, _ := m.Status(id); return st.State == Running && st.Bytes > 0 }
	waitFor(t, 5*time.Second, func() bool { return progressing(a) && progressing(b) })

	// Discard a running job: row gone, output and sidecar gone.
	if err := m.Discard(a); err != nil {
		t.Fatalf("Discard: %v", err)
	}
	if _, ok := m.Status(a); ok {
		t.Fatal("job still listed after Discard")
	}
	for _, p := range []string{filepath.Join(dir, "a.bin"), filepath.Join(dir, "a.bin.part"), filepath.Join(dir, "a.bin.spate")} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("%s still exists after Discard (err=%v)", p, err)
		}
	}

	// Cancel keeps the partial (resumable); clearing the cancelled row deletes it.
	if err := m.Cancel(b); err != nil {
		t.Fatalf("Cancel: %v", err)
	}
	waitFor(t, 5*time.Second, func() bool { st, _ := m.Status(b); return st.State == Cancelled })
	if _, err := os.Stat(download.PartPath(filepath.Join(dir, "b.bin"))); err != nil {
		t.Fatalf("partial should survive Cancel: %v", err)
	}
	if n := m.ClearFinished(); n != 1 {
		t.Fatalf("ClearFinished = %d, want 1", n)
	}
	for _, p := range []string{filepath.Join(dir, "b.bin"), filepath.Join(dir, "b.bin.part"), filepath.Join(dir, "b.bin.spate")} {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Fatalf("%s still exists after ClearFinished (err=%v)", p, err)
		}
	}
}

func TestVersionAdvancesOnChange(t *testing.T) {
	m := New(1)
	v0 := m.Version()
	id, err := m.Add(Spec{URL: "http://x/a", Out: filepath.Join(t.TempDir(), "a")})
	if err != nil {
		t.Fatal(err)
	}
	if m.Version() <= v0 {
		t.Fatal("Add did not bump version")
	}
	v1 := m.Version()
	if err := m.Pause(id); err != nil {
		t.Fatal(err)
	}
	if m.Version() <= v1 {
		t.Fatal("Pause did not bump version")
	}
}

func TestRecordsRoundTrip(t *testing.T) {
	m := New(1)
	out := filepath.Join(t.TempDir(), "a.bin")
	at := time.Now().Add(time.Hour).Truncate(time.Second)
	id, err := m.Add(Spec{URL: "http://x/a", Out: out, Priority: 3, StartAt: at,
		Options: download.Options{Conns: 2, Cookie: "s=1", Headers: map[string]string{"Referer": "http://x/"}}})
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Pause(id); err != nil {
		t.Fatal(err)
	}
	recs := m.Records()
	if len(recs) != 1 || !recs[0].Paused || recs[0].Cookie != "s=1" || recs[0].Headers["Referer"] != "http://x/" ||
		!recs[0].StartAt.Equal(at) || recs[0].Priority != 3 || recs[0].Conns != 2 || recs[0].Out != out {
		t.Fatalf("record lost fields: %+v", recs)
	}
	// Terminal jobs are recorded as history: state and finish time, no
	// request customisation (nothing will run again).
	if err := m.Cancel(id); err != nil {
		t.Fatal(err)
	}
	got := m.Records()
	if len(got) != 1 || got[0].State != "cancelled" || got[0].FinishedAt.IsZero() || got[0].Cookie != "" {
		t.Fatalf("cancelled job not recorded as history: %+v", got)
	}

	m2 := New(1)
	nid, err := m2.AddRecord(recs[0], download.Options{})
	if err != nil {
		t.Fatal(err)
	}
	st, ok := m2.Status(nid)
	if !ok || st.State != Paused || st.Priority != 3 || !st.StartAt.Equal(at) || st.Out != out {
		t.Fatalf("restored wrong: %+v", st)
	}
	// The restored spec carries the request customisation and resumes.
	m2.mu.Lock()
	j := m2.jobs[nid]
	m2.mu.Unlock()
	if j.Options.Cookie != "s=1" || j.Options.Headers["Referer"] != "http://x/" || !j.Options.Resume || j.Options.Conns != 2 {
		t.Fatalf("restored options wrong: %+v", j.Options)
	}
}

func TestDiscardKeepsUnrelatedFileAtOutput(t *testing.T) {
	// A finished file (or any user file) sits at out; a new job for that name
	// writes only out.part. Removing the job must not touch the existing file.
	dir := t.TempDir()
	out := filepath.Join(dir, "f.bin")
	if err := os.WriteFile(out, []byte("keep me"), 0o644); err != nil {
		t.Fatal(err)
	}
	m := New(1)
	m.SetStartGate(func() bool { return false })
	id, err := m.Add(Spec{URL: "http://127.0.0.1:1/f.bin", Out: out})
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Cancel(id); err != nil {
		t.Fatal(err)
	}
	if n := m.ClearFinished(); n != 1 {
		t.Fatalf("ClearFinished = %d", n)
	}
	if b, err := os.ReadFile(out); err != nil || string(b) != "keep me" {
		t.Fatalf("existing file touched: %q %v", b, err)
	}
	id2, _ := m.Add(Spec{URL: "http://127.0.0.1:1/f.bin", Out: out})
	if err := m.Discard(id2); err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(out); err != nil || string(b) != "keep me" {
		t.Fatalf("existing file touched by Discard: %q %v", b, err)
	}
}

func TestRestoredIDsDoNotCollide(t *testing.T) {
	m := New(1)
	m.SetStartGate(func() bool { return false })
	if _, err := m.AddRecord(Record{ID: "job-3", URL: "http://x/a", Out: filepath.Join(t.TempDir(), "a")}, download.Options{}); err != nil {
		t.Fatal(err)
	}
	a, err := m.Add(Spec{URL: "http://x/b"})
	if err != nil {
		t.Fatal(err)
	}
	b, err := m.Add(Spec{URL: "http://x/c"})
	if err != nil {
		t.Fatalf("second add after restore: %v", err)
	}
	if a != "job-4" || b != "job-5" {
		t.Fatalf("ids after restoring job-3: %s, %s", a, b)
	}
}

func TestShutdownRecordsRunningAsPending(t *testing.T) {
	data := blob(8 << 20)
	srv := httptest.NewServer(rangeServer(data, 50*time.Millisecond, nil, nil, nil))
	defer srv.Close()
	m := New(1)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = m.Serve(ctx) }()
	out := filepath.Join(t.TempDir(), "big.bin")
	id, err := m.Add(Spec{URL: srv.URL, Out: out, Options: download.Options{Conns: 2, MinSegment: 1 << 20}})
	if err != nil {
		t.Fatal(err)
	}
	waitFor(t, 5*time.Second, func() bool { st, _ := m.Status(id); return st.State == Running && st.Bytes > 0 })
	m.Shutdown()
	st, _ := m.Status(id)
	if st.State != Pending {
		t.Fatalf("after Shutdown state = %s, want pending", st.State)
	}
	recs := m.Records()
	if len(recs) != 1 || recs[0].Paused {
		t.Fatalf("records after shutdown: %+v", recs)
	}
	// Nothing starts after Shutdown even though a slot is free.
	time.Sleep(200 * time.Millisecond)
	if st, _ := m.Status(id); st.State != Pending {
		t.Fatalf("job restarted after Shutdown: %s", st.State)
	}
}

func TestSeveralScheduledJobsAndReschedule(t *testing.T) {
	m := New(2)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = m.Serve(ctx) }()
	later := time.Now().Add(time.Hour)
	ids := make([]string, 0, 3)
	for i := 0; i < 3; i++ {
		id, err := m.Add(Spec{URL: fmt.Sprintf("http://127.0.0.1:1/f%d.bin", i), Out: filepath.Join(t.TempDir(), "f.bin"), StartAt: later.Add(time.Duration(i) * time.Minute)})
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, id)
	}
	time.Sleep(100 * time.Millisecond)
	for i, id := range ids {
		st, _ := m.Status(id)
		if st.State != Pending || !st.StartAt.Equal(later.Add(time.Duration(i)*time.Minute)) {
			t.Fatalf("job %s: %s at %v", id, st.State, st.StartAt)
		}
	}
	// Reschedule one further out, clear another (it then tries to start and
	// fails on the dead port, which is fine: it left the schedule).
	far := later.Add(24 * time.Hour)
	if err := m.SetStartAt(ids[0], far); err != nil {
		t.Fatal(err)
	}
	if st, _ := m.Status(ids[0]); !st.StartAt.Equal(far) {
		t.Fatalf("reschedule not applied: %v", st.StartAt)
	}
	if err := m.SetStartAt(ids[1], time.Time{}); err != nil {
		t.Fatal(err)
	}
	waitFor(t, 5*time.Second, func() bool {
		st, _ := m.Status(ids[1])
		return st.State != Pending || st.StartAt.IsZero() && st.State == Pending
	})
	if st, _ := m.Status(ids[2]); st.State != Pending {
		t.Fatalf("untouched job changed: %s", st.State)
	}
	if err := m.SetStartAt("nope", far); err == nil {
		t.Fatal("unknown job accepted")
	}
}

func TestHistoryRestoredAsDone(t *testing.T) {
	m := New(1)
	at := time.Now().Add(-time.Hour).Truncate(time.Second)
	id, err := m.AddRecord(Record{ID: "job-3", URL: "http://x/a", Out: "/dl/a.bin", State: "done", FinishedAt: at, Bytes: 100, Total: 100}, download.Options{})
	if err != nil {
		t.Fatal(err)
	}
	st, _ := m.Status(id)
	if st.State != Done || !st.FinishedAt.Equal(at) || st.Bytes != 100 || st.Total != 100 {
		t.Fatalf("restored history wrong: %+v", st)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = m.Serve(ctx) }()
	time.Sleep(150 * time.Millisecond)
	if st, _ := m.Status(id); st.State != Done {
		t.Fatalf("history job ran: %s", st.State)
	}
	if _, err := m.AddRecord(Record{ID: "job-4", URL: "http://x/b", Out: "/dl/b", State: "weird"}, download.Options{}); err == nil {
		t.Fatal("unknown terminal state accepted")
	}
	recs := m.Records()
	if len(recs) != 1 || recs[0].State != "done" || recs[0].Bytes != 100 {
		t.Fatalf("history not recorded: %+v", recs)
	}
}

func TestRecordsCapHistory(t *testing.T) {
	m := New(1)
	old := time.Now().Add(-HistoryFor - time.Hour)
	for i := 0; i < HistoryMax+5; i++ {
		_, _ = m.AddRecord(Record{ID: fmt.Sprintf("job-%d", i+1), URL: "http://x/f", Out: fmt.Sprintf("/dl/%d", i), State: "done", FinishedAt: time.Now().Add(time.Duration(i) * time.Second)}, download.Options{})
	}
	_, _ = m.AddRecord(Record{ID: "job-old", URL: "http://x/o", Out: "/dl/o", State: "done", FinishedAt: old}, download.Options{})
	recs := m.Records()
	if len(recs) != HistoryMax {
		t.Fatalf("history records = %d, want %d", len(recs), HistoryMax)
	}
	for _, r := range recs {
		if r.ID == "job-old" || r.ID == "job-1" || r.ID == "job-5" {
			t.Fatalf("expired or oldest record kept: %s", r.ID)
		}
	}
}

func TestPauseAllResumeAll(t *testing.T) {
	m := New(2)
	m.SetStartGate(func() bool { return false })
	a, _ := m.Add(Spec{URL: "http://x/a"})
	b, _ := m.Add(Spec{URL: "http://x/b"})
	m.PauseAll()
	for _, id := range []string{a, b} {
		if st, _ := m.Status(id); st.State != Paused {
			t.Fatalf("%s not paused: %s", id, st.State)
		}
	}
	m.ResumeAll()
	for _, id := range []string{a, b} {
		if st, _ := m.Status(id); st.State != Pending {
			t.Fatalf("%s not resumed: %s", id, st.State)
		}
	}
}
