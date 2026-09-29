// Package service composes the download engine into the long-lived app
// service every UI shell embeds: the job manager, the loopback capture endpoint
// (with a persisted token), orphan resume, browser-extension pairing, and the
// user's settings (destination rules, bandwidth limits and windows, download
// window, recurring downloads). Shells stay thin: they render status and
// forward user actions.
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
	"cascade/internal/settings"
)

// PairTimeout bounds how long a pairing request waits for the user's decision.
const PairTimeout = 90 * time.Second

// schedulerTick is how often limit windows, the download window and recurring
// downloads are re-evaluated.
const schedulerTick = 30 * time.Second

// ErrAlreadyRunning is returned by Start when another Cascade instance already
// answers on the capture ports; a shell should exit quietly (or defer to it).
var ErrAlreadyRunning = errors.New("cascade is already running")

// AddOpts describes a download to enqueue.
type AddOpts struct {
	URL      string
	Dir      string // "" = resolved by settings (site/category rules)
	SHA256   string
	Conns    int
	Priority int
	StartAt  time.Time // zero = as soon as possible
}

// Service is the running app core.
type Service struct {
	Mgr      *job.Manager
	API      *localapi.Server
	Settings *settings.Settings
	Dir      string // default download directory (settings base)
	Token    string
	Addr     string // capture endpoint address ("" if it failed to bind)

	settingsPath string
	limiter      *download.Limiter // global cap shared by all downloads
	cancel       context.CancelFunc

	pairMu      sync.Mutex
	pairPending bool
	pairCh      chan bool
}

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

// Start brings the service up: settings, manager loop, capture endpoint,
// orphan resume, scheduler. downloadDir "" selects the settings/platform
// default. It refuses to start a second instance (ErrAlreadyRunning).
func Start(maxConcurrent int, downloadDir string) (*Service, error) {
	// CASCADE_ALLOW_MULTIPLE=1 disables the guard (tests, development).
	if os.Getenv("CASCADE_ALLOW_MULTIPLE") != "1" && AlreadyRunning() {
		return nil, ErrAlreadyRunning
	}
	if downloadDir == "" {
		downloadDir = DefaultDownloadDir()
	}
	spath := os.Getenv("CASCADE_SETTINGS")
	if spath == "" {
		spath, _ = settings.Path()
	}
	st, err := settings.Load(spath, downloadDir)
	if err != nil {
		return nil, err
	}
	if maxConcurrent <= 0 {
		maxConcurrent = st.MaxConcurrent
	}

	mgr := job.New(maxConcurrent)
	ctx, cancel := context.WithCancel(context.Background())
	go func() { _ = mgr.Serve(ctx) }()

	s := &Service{
		Mgr: mgr, Settings: st, Dir: st.Snapshot().DownloadDir, Token: LoadOrCreateToken(),
		settingsPath: spath, limiter: download.NewSharedLimiter(), cancel: cancel,
	}
	s.limiter.SetRate(st.EffectiveLimit(time.Now()))
	mgr.SetStartGate(func() bool { return s.Settings.MayStart(time.Now()) })

	s.API = localapi.New(mgr, s.Token, s.Dir)
	s.API.PairFunc = s.pairFunc
	s.API.ResolveDir = s.Resolve
	if addr, err := s.API.Start(); err == nil {
		s.Addr = addr
	}
	ResumeOrphans(mgr, s.Dir, s.limiter)
	go s.scheduler(ctx)
	return s, nil
}

// Stop shuts the service down.
func (s *Service) Stop() {
	if s.API != nil {
		_ = s.API.Close()
	}
	s.cancel()
}

// Resolve picks the folder for a download per the settings rules.
func (s *Service) Resolve(rawURL, filename string) string {
	return s.Settings.Resolve(rawURL, filename)
}

// AddWith enqueues a download described by o.
func (s *Service) AddWith(o AddOpts) (string, error) {
	if _, err := url.ParseRequestURI(o.URL); err != nil {
		return "", fmt.Errorf("invalid URL")
	}
	name := FilenameFor(o.URL)
	dir := o.Dir
	if dir == "" {
		dir = s.Resolve(o.URL, name)
	}
	return s.Mgr.Add(job.Spec{
		URL: o.URL, Out: filepath.Join(dir, name), Priority: o.Priority, StartAt: o.StartAt,
		Options: download.Options{Conns: o.Conns, SHA256: o.SHA256, Resume: true, SharedLimiter: s.limiter},
	})
}

// Add enqueues a download (compat wrapper around AddWith).
func (s *Service) Add(rawURL, dir, sha256 string, conns int) (string, error) {
	return s.AddWith(AddOpts{URL: rawURL, Dir: dir, SHA256: sha256, Conns: conns})
}

// SettingsJSON returns the current settings document.
func (s *Service) SettingsJSON() ([]byte, error) { return s.Settings.JSON() }

// ApplySettings replaces the settings from JSON, persists them, and applies
// the parts that take effect immediately (limit, download window, base dir).
func (s *Service) ApplySettings(b []byte) error {
	if err := s.Settings.Apply(b); err != nil {
		return err
	}
	if err := s.Settings.Save(s.settingsPath); err != nil {
		return err
	}
	s.Dir = s.Settings.Snapshot().DownloadDir
	s.limiter.SetRate(s.Settings.EffectiveLimit(time.Now()))
	s.Mgr.SetStartGate(func() bool { return s.Settings.MayStart(time.Now()) }) // re-signals the loop
	return nil
}

// CurrentLimit returns the bytes/sec cap in force (0 = unlimited).
func (s *Service) CurrentLimit() int64 { return s.limiter.Rate() }

// scheduler applies time-based policy: limit windows, and recurring downloads.
func (s *Service) scheduler(ctx context.Context) {
	t := time.NewTicker(schedulerTick)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			s.limiter.SetRate(s.Settings.EffectiveLimit(now))
			due := s.Settings.Due(now)
			for _, r := range due {
				_, _ = s.AddWith(AddOpts{URL: r.URL, Dir: r.Dir})
			}
			if len(due) > 0 {
				_ = s.Settings.Save(s.settingsPath) // NextAt advanced
			}
		}
	}
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

// ResumeOrphans re-queues downloads whose .cascade sidecar is still present
// under dir (searched one level of subfolders deep, for category folders),
// continuing from where they stopped. limiter may be nil.
func ResumeOrphans(mgr *job.Manager, dir string, limiter *download.Limiter) int {
	sidecars, _ := filepath.Glob(filepath.Join(dir, "*.cascade"))
	nested, _ := filepath.Glob(filepath.Join(dir, "*", "*.cascade"))
	n := 0
	for _, sc := range append(sidecars, nested...) {
		out := strings.TrimSuffix(sc, ".cascade")
		ctrl, err := download.LoadControl(out)
		if err != nil || ctrl == nil || ctrl.URL == "" {
			continue
		}
		if _, err := os.Stat(out); err != nil {
			continue
		}
		if _, err := mgr.Add(job.Spec{URL: ctrl.URL, Out: out, Options: download.Options{Resume: true, SharedLimiter: limiter}}); err == nil {
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
