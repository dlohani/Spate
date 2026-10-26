package service

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"spate/internal/job"
)

func TestSettingsRulesAndPersistence(t *testing.T) {
	t.Setenv("SPATE_TOKEN", "test-token")
	t.Setenv("SPATE_ALLOW_MULTIPLE", "1")
	dir := t.TempDir()
	t.Setenv("SPATE_SETTINGS", filepath.Join(dir, "settings.json"))

	data := make([]byte, 64<<10)
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "clip.mp4", time.Now(), bytes.NewReader(data))
	}))
	defer origin.Close()

	s, err := Start(2, dir)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Stop()

	// Turn on category organization + a site rule; must persist and apply.
	if err := s.ApplySettings([]byte(`{"organizeByCategory":true,"siteRules":[{"host":"127.0.0.1","dir":"Local"}],"limits":{"bytesPerSec":123456}}`)); err != nil {
		t.Fatal(err)
	}
	if s.CurrentLimit() != 123456 {
		t.Fatalf("limit not applied: %d", s.CurrentLimit())
	}
	if _, err := os.Stat(filepath.Join(dir, "settings.json")); err != nil {
		t.Fatal("settings not persisted")
	}
	// Site rule wins over the Video category for this origin (127.0.0.1).
	id, err := s.AddWith(AddOpts{URL: origin.URL + "/clip.mp4", Conns: 1})
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if st, ok := s.Mgr.Status(id); ok && st.State == job.Done {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if _, err := os.Stat(filepath.Join(dir, "Local", "clip.mp4")); err != nil {
		t.Fatalf("expected the site rule folder: %v", err)
	}
	// Without a site rule, the category folder applies (Video).
	if err := s.ApplySettings([]byte(`{"organizeByCategory":true}`)); err != nil {
		t.Fatal(err)
	}
	if got := s.Resolve("https://example.com/movie.mkv", "movie.mkv"); got != filepath.Join(dir, "Video") {
		t.Fatalf("category resolve = %s", got)
	}
	// Scheduled add is pending with StartAt set; StartNow releases it.
	id2, err := s.AddWith(AddOpts{URL: origin.URL + "/later.bin", Conns: 1, StartAt: time.Now().Add(time.Hour)})
	if err != nil {
		t.Fatal(err)
	}
	if st, _ := s.Mgr.Status(id2); st.State != job.Pending || st.StartAt.IsZero() {
		t.Fatalf("scheduled job: %+v", st)
	}
	if err := s.Mgr.StartNow(id2); err != nil {
		t.Fatal(err)
	}
}

func TestStartAddAndPair(t *testing.T) {
	t.Setenv("SPATE_TOKEN", "test-token")
	t.Setenv("SPATE_ALLOW_MULTIPLE", "1") // a real Spate may be running on this machine
	dir := t.TempDir()
	t.Setenv("SPATE_SETTINGS", filepath.Join(dir, "settings.json"))

	data := make([]byte, 512<<10)
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.ServeContent(w, r, "f.bin", time.Now(), bytes.NewReader(data))
	}))
	defer origin.Close()

	s, err := Start(2, dir)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Stop()
	if s.Token != "test-token" || s.Dir != dir {
		t.Fatalf("service config: token=%q dir=%q", s.Token, s.Dir)
	}

	id, err := s.Add(origin.URL+"/f.bin", "", "", 2)
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if st, ok := s.Mgr.Status(id); ok && st.State == job.Done {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	got, err := os.ReadFile(filepath.Join(dir, "f.bin"))
	if err != nil || !bytes.Equal(got, data) {
		t.Fatalf("download via service failed: err=%v len=%d", err, len(got))
	}

	// Pairing: a request appears as pending until the shell resolves it.
	if s.PairPending() {
		t.Fatal("no pairing should be pending initially")
	}
	result := make(chan bool, 1)
	go func() { result <- s.API.PairFunc() }()
	deadline = time.Now().Add(2 * time.Second)
	for !s.PairPending() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if !s.PairPending() {
		t.Fatal("pairing request did not become pending")
	}
	s.ResolvePair(true)
	select {
	case ok := <-result:
		if !ok {
			t.Fatal("expected pairing to be allowed")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("pairing did not resolve")
	}
	if s.PairPending() {
		t.Fatal("pending flag should clear after resolve")
	}
}
