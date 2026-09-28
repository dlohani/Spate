// Package service composes the download engine into the long-lived app
// service every UI shell embeds: the job manager, the loopback capture endpoint
// (with a persisted token), orphan resume, and browser-extension pairing.
// Shells (Fyne, Flutter via the C ABI, mobile) stay thin: they render status
// and forward user actions.
package service

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"cascade/internal/download"
	"cascade/internal/job"
	"cascade/internal/localapi"
)

// PairTimeout bounds how long a pairing request waits for the user's decision.
const PairTimeout = 90 * time.Second

// Service is the running app core.
type Service struct {
	Mgr   *job.Manager
	API   *localapi.Server
	Dir   string // default download directory
	Token string
	Addr  string // capture endpoint address ("" if it failed to bind)

	cancel context.CancelFunc

	pairMu      sync.Mutex
	pairPending bool
	pairCh      chan bool
}

// ErrAlreadyRunning is returned by Start when another Cascade instance already
// answers on the capture ports; a shell should exit quietly (or defer to it).
var ErrAlreadyRunning = errors.New("cascade is already running")

// AlreadyRunning reports whether a Cascade capture endpoint is already up on
// one of the ports the browser extension probes.
func AlreadyRunning() bool {
	c := &http.Client{Timeout: 300 * time.Millisecond}
	for _, p := range []int{localapi.DefaultPort, localapi.DefaultPort + 1, localapi.DefaultPort + 2} {
		resp, err := c.Get(fmt.Sprintf("http://127.0.0.1:%d/ping", p))
		if err != nil {
			continue
		}
		var body struct {
			App string `json:"app"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&body)
		resp.Body.Close()
		if body.App == "cascade" {
			return true
		}
	}
	return false
}

// Start brings the service up: manager loop, capture endpoint, orphan resume.
// downloadDir "" selects the platform default. It refuses to start a second
// instance (ErrAlreadyRunning) so login items, the native host and manual
// launches can never stack up duplicate resident apps.
func Start(maxConcurrent int, downloadDir string) (*Service, error) {
	// CASCADE_ALLOW_MULTIPLE=1 disables the guard (tests, development).
	if os.Getenv("CASCADE_ALLOW_MULTIPLE") != "1" && AlreadyRunning() {
		return nil, ErrAlreadyRunning
	}
	if downloadDir == "" {
		downloadDir = DefaultDownloadDir()
	}
	mgr := job.New(maxConcurrent)
	ctx, cancel := context.WithCancel(context.Background())
	go func() { _ = mgr.Serve(ctx) }()

	s := &Service{Mgr: mgr, Dir: downloadDir, Token: LoadOrCreateToken(), cancel: cancel}
	s.API = localapi.New(mgr, s.Token, downloadDir)
	s.API.PairFunc = s.pairFunc
	if addr, err := s.API.Start(); err == nil {
		s.Addr = addr
	}
	ResumeOrphans(mgr, downloadDir)
	return s, nil
}

// Stop shuts the service down.
func (s *Service) Stop() {
	if s.API != nil {
		_ = s.API.Close()
	}
	s.cancel()
}

// Add enqueues a download of rawURL into dir (default Dir) with conns
// connections and an optional expected SHA-256.
func (s *Service) Add(rawURL, dir, sha256 string, conns int) (string, error) {
	if _, err := url.ParseRequestURI(rawURL); err != nil {
		return "", fmt.Errorf("invalid URL")
	}
	if dir == "" {
		dir = s.Dir
	}
	out := filepath.Join(dir, FilenameFor(rawURL))
	return s.Mgr.Add(job.Spec{URL: rawURL, Out: out, Options: download.Options{Conns: conns, SHA256: sha256, Resume: true}})
}

// PairPending reports whether a browser extension is waiting for the user to
// allow or deny a connection. A shell polls this and shows a prompt.
func (s *Service) PairPending() bool {
	s.pairMu.Lock()
	defer s.pairMu.Unlock()
	return s.pairPending
}

// ResolvePair answers the pending pairing request.
func (s *Service) ResolvePair(ok bool) {
	s.pairMu.Lock()
	ch := s.pairCh
	s.pairMu.Unlock()
	if ch != nil {
		select {
		case ch <- ok:
		default:
		}
	}
}

func (s *Service) pairFunc() bool {
	s.pairMu.Lock()
	if s.pairPending {
		s.pairMu.Unlock()
		return false
	}
	ch := make(chan bool, 1)
	s.pairCh = ch
	s.pairPending = true
	s.pairMu.Unlock()
	defer func() {
		s.pairMu.Lock()
		s.pairPending = false
		s.pairCh = nil
		s.pairMu.Unlock()
	}()
	select {
	case ok := <-ch:
		return ok
	case <-time.After(PairTimeout):
		return false
	}
}

// DefaultDownloadDir is ~/Downloads when it exists, else the home directory.
func DefaultDownloadDir() string {
	if home, err := os.UserHomeDir(); err == nil {
		d := filepath.Join(home, "Downloads")
		if fi, err := os.Stat(d); err == nil && fi.IsDir() {
			return d
		}
		return home
	}
	return "."
}

// LoadOrCreateToken returns a stable capture token: CASCADE_TOKEN if set, else
// one persisted under the user config dir (generated once).
func LoadOrCreateToken() string {
	if t := os.Getenv("CASCADE_TOKEN"); t != "" {
		return t
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		return randToken()
	}
	cdir := filepath.Join(dir, "cascade")
	tokenPath := filepath.Join(cdir, "token")
	if b, err := os.ReadFile(tokenPath); err == nil {
		if t := strings.TrimSpace(string(b)); t != "" {
			return t
		}
	}
	t := randToken()
	if err := os.MkdirAll(cdir, 0o700); err == nil {
		_ = os.WriteFile(tokenPath, []byte(t), 0o600)
	}
	return t
}

func randToken() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "cascade-token"
	}
	return hex.EncodeToString(b)
}

// ResumeOrphans re-queues downloads whose .cascade sidecar is still present in
// dir (left by a crash, quit, or restart), continuing from where they stopped.
func ResumeOrphans(mgr *job.Manager, dir string) int {
	sidecars, _ := filepath.Glob(filepath.Join(dir, "*.cascade"))
	n := 0
	for _, sc := range sidecars {
		out := strings.TrimSuffix(sc, ".cascade")
		ctrl, err := download.LoadControl(out)
		if err != nil || ctrl == nil || ctrl.URL == "" {
			continue
		}
		if _, err := os.Stat(out); err != nil {
			continue
		}
		if _, err := mgr.Add(job.Spec{URL: ctrl.URL, Out: out, Options: download.Options{Resume: true}}); err == nil {
			n++
		}
	}
	return n
}

// FilenameFor derives a file name from a URL path, defaulting to download.bin.
func FilenameFor(rawURL string) string {
	if u, err := url.Parse(rawURL); err == nil {
		if base := path.Base(u.Path); base != "" && base != "/" && base != "." {
			return base
		}
	}
	return "download.bin"
}
