package service

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"cascade/internal/download"
	"cascade/internal/job"
)

func startTest(t *testing.T, dir string) *Service {
	t.Helper()
	t.Setenv("CASCADE_TOKEN", "test-token")
	s, err := StartWith(StartOpts{MaxConcurrent: 1, DownloadDir: dir,
		SettingsPath: filepath.Join(dir, "settings.json"), AllowMultiple: true})
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestQueueSurvivesRestart(t *testing.T) {
	dir := t.TempDir()
	s := startTest(t, dir)
	s.Mgr.SetStartGate(func() bool { return false }) // nothing runs: states stay as set
	out := filepath.Join(dir, "a.bin")
	id, err := s.Mgr.Add(job.Spec{URL: "http://127.0.0.1:1/a.bin", Out: out, Priority: 2,
		Options: download.Options{Cookie: "s=1", Headers: map[string]string{"Referer": "http://x/"}}})
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Mgr.Pause(id); err != nil {
		t.Fatal(err)
	}
	at := time.Now().Add(time.Hour).Truncate(time.Second)
	if _, err := s.AddWith(AddOpts{URL: "http://127.0.0.1:1/b.bin", StartAt: at}); err != nil {
		t.Fatal(err)
	}
	s.Stop()
	if _, err := os.Stat(queuePath(filepath.Join(dir, "settings.json"))); err != nil {
		t.Fatalf("queue.json not written: %v", err)
	}
	// The core logged what it did, beside settings.json.
	logb, err := os.ReadFile(filepath.Join(dir, "cascade.log"))
	if err != nil {
		t.Fatalf("cascade.log not written: %v", err)
	}
	for _, want := range []string{"msg=started", "msg=\"job added\"", "msg=stopped"} {
		if !strings.Contains(string(logb), want) {
			t.Fatalf("cascade.log lacks %s:\n%s", want, logb)
		}
	}

	s2 := startTest(t, dir)
	s2.Mgr.SetStartGate(func() bool { return false })
	defer s2.Stop()
	recs := s2.Mgr.Records()
	if len(recs) != 2 {
		t.Fatalf("restored %d jobs, want 2: %+v", len(recs), recs)
	}
	if recs[0].Out != out || !recs[0].Paused || recs[0].Cookie != "s=1" || recs[0].Headers["Referer"] != "http://x/" || recs[0].Priority != 2 {
		t.Fatalf("paused job lost fields: %+v", recs[0])
	}
	if recs[1].Paused || !recs[1].StartAt.Equal(at) {
		t.Fatalf("scheduled job lost fields: %+v", recs[1])
	}
	sts := s2.Mgr.Statuses()
	if sts[0].State != job.Paused || sts[1].State != job.Pending {
		t.Fatalf("states after restore: %s, %s", sts[0].State, sts[1].State)
	}
}

func TestLoadQueueRejectsGarbage(t *testing.T) {
	dir := t.TempDir()
	qp := queuePath(filepath.Join(dir, "settings.json"))
	if err := os.WriteFile(qp, []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadQueue(qp); err == nil {
		t.Fatal("garbage queue accepted")
	}
	if err := os.WriteFile(qp, []byte(`{"version":99,"jobs":[]}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadQueue(qp); err == nil {
		t.Fatal("future queue version accepted")
	}
	s := startTest(t, dir) // starts anyway, with an empty queue
	defer s.Stop()
	if n := len(s.Mgr.Records()); n != 0 {
		t.Fatalf("expected empty queue, got %d", n)
	}
}

func TestOrphanScanSkipsQueuedOutputs(t *testing.T) {
	dir := t.TempDir()
	out := filepath.Join(dir, "o.bin")
	// A sidecar plus partial data for out, and a queue record for the same out.
	segs := download.PlanSegments(1<<20, 2, 1<<19)
	if err := download.NewControl(out, "http://127.0.0.1:1/o.bin", 1<<20, `"v1"`, segs).Save(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(download.PartPath(out), make([]byte, 1<<20), 0o644); err != nil {
		t.Fatal(err)
	}
	qp := queuePath(filepath.Join(dir, "settings.json"))
	if err := saveQueue(qp, []job.Record{{ID: "job-7", URL: "http://127.0.0.1:1/o.bin", Out: out, Paused: true}}); err != nil {
		t.Fatal(err)
	}
	s := startTest(t, dir)
	defer s.Stop()
	sts := s.Mgr.Statuses()
	if len(sts) != 1 || sts[0].ID != "job-7" || sts[0].State != job.Paused {
		t.Fatalf("expected exactly the queued job, got %+v", sts)
	}
}
