package service

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"cascade/internal/job"
)

func TestStartAddAndPair(t *testing.T) {
	t.Setenv("CASCADE_TOKEN", "test-token")
	t.Setenv("CASCADE_ALLOW_MULTIPLE", "1") // a real Cascade may be running on this machine
	dir := t.TempDir()

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
