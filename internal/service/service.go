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
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"spate/internal/download"
	"spate/internal/job"
	"spate/internal/localapi"
	"spate/internal/logx"
	"spate/internal/paths"
	"spate/internal/settings"
	"spate/internal/version"
)

// logMaxBytes bounds spate.log before it is rotated to spate.log.1.
const logMaxBytes = 5 << 20

// PairTimeout bounds how long a pairing request waits for the user's decision.
const PairTimeout = 90 * time.Second

// schedulerTick is how often limit windows, the download window and recurring
// downloads are re-evaluated.
const schedulerTick = 30 * time.Second

// ErrAlreadyRunning is returned by Start when another Spate instance already
// answers on the capture ports; a shell should exit quietly (or defer to it).
var ErrAlreadyRunning = errors.New("spate is already running")

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
	queue        *queuePersister

	pairMu      sync.Mutex
	pairPending bool
	pairCh      chan bool
}

// AlreadyRunning reports whether a Spate capture endpoint is already up on
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
		if body.App == "spate" {
			return true
		}
	}
	return false
}

// RequestShow asks an already running instance to show its window. A second
// launch of the app calls this instead of starting a service, then exits.
// Returns false if no instance answered.
func RequestShow() bool {
	token := LoadOrCreateToken()
	c := &http.Client{Timeout: 500 * time.Millisecond}
	for _, p := range []int{localapi.DefaultPort, localapi.DefaultPort + 1, localapi.DefaultPort + 2} {
		req, err := http.NewRequest(http.MethodPost, fmt.Sprintf("http://127.0.0.1:%d/show", p), nil)
		if err != nil {
			continue
		}
		req.Header.Set("X-Spate-Token", token)
		resp, err := c.Do(req)
		if err != nil {
			continue
		}
		resp.Body.Close()
		if resp.StatusCode == http.StatusOK {
			return true
		}
	}
	return false
}

// ShowPending reports (and clears) whether another launch asked this instance
// to show its window.
func (s *Service) ShowPending() bool { return s.API != nil && s.API.ShowPending() }

// StartOpts configures Start. Zero values select the defaults: settings-file
// concurrency, platform download folder, per-user settings path, and the
// single-instance guard.
type StartOpts struct {
	MaxConcurrent int
	DownloadDir   string
	SettingsPath  string // "" = SPATE_SETTINGS env, else settings.Path()
	AllowMultiple bool   // skip the single-instance guard (tests, development)
	Token         string // "" = SPATE_TOKEN env, else the persisted per-user token
}

// Start brings the service up: settings, manager loop, capture endpoint,
// orphan resume, scheduler. downloadDir "" selects the settings/platform
// default. It refuses to start a second instance (ErrAlreadyRunning).
func Start(maxConcurrent int, downloadDir string) (*Service, error) {
	return StartWith(StartOpts{MaxConcurrent: maxConcurrent, DownloadDir: downloadDir})
}

// StartWith is Start with every option explicit; front-ends that cannot set
// environment variables (dart:ffi tests) use it to keep their settings file
// out of the user's config folder.
func StartWith(o StartOpts) (*Service, error) {
	maxConcurrent, downloadDir := o.MaxConcurrent, o.DownloadDir
	// SPATE_ALLOW_MULTIPLE=1 disables the guard (tests, development).
	if !o.AllowMultiple && os.Getenv("SPATE_ALLOW_MULTIPLE") != "1" && AlreadyRunning() {
		return nil, ErrAlreadyRunning
	}
	if downloadDir == "" {
		downloadDir = DefaultDownloadDir()
	}
	spath := o.SettingsPath
	if spath == "" {
		spath = os.Getenv("SPATE_SETTINGS")
	}
	if spath == "" {
		spath, _ = settings.Path()
	}
	// The core logs to a file beside settings.json; a shell has nowhere
	// else to show what the engine, queue and capture endpoint decided.
	if lg, err := logx.ToFile(filepath.Join(filepath.Dir(spath), "spate.log"), logMaxBytes); err == nil {
		slog.SetDefault(lg)
	}
	st, err := settings.Load(spath, downloadDir)
	if err != nil {
		slog.Error("settings load failed", "path", spath, "err", err)
		return nil, err
	}
	if maxConcurrent <= 0 {
		maxConcurrent = st.MaxConcurrent
	}

	mgr := job.New(maxConcurrent)
	ctx, cancel := context.WithCancel(context.Background())
	go func() { _ = mgr.Serve(ctx) }()

	token := o.Token
	if token == "" {
		token = LoadOrCreateToken()
	}
	s := &Service{
		Mgr: mgr, Settings: st, Dir: st.Snapshot().DownloadDir, Token: token,
		settingsPath: spath, limiter: download.NewSharedLimiter(), cancel: cancel,
	}
	s.limiter.SetRate(st.EffectiveLimit(time.Now()))
	mgr.SetStartGate(func() bool { return s.Settings.MayStart(time.Now()) })

	// The queue as it was when the app last stopped (paused, scheduled and
	// in-flight jobs with their request customisation), then any partial a
	// sidecar still describes that the queue does not know about.
	qp := queuePath(spath)
	if recs, err := loadQueue(qp); err != nil {
		slog.Warn("queue load failed; starting with an empty queue", "path", qp, "err", err)
	} else {
		n := 0
		for _, r := range recs {
			if _, err := mgr.AddRecord(r, download.Options{SharedLimiter: s.limiter}); err == nil {
				n++
			} else {
				slog.Warn("queue record skipped", "id", r.ID, "err", err)
			}
		}
		if n > 0 {
			slog.Info("queue restored", "jobs", n)
		}
	}
	if n := ResumeOrphans(mgr, s.Dir, s.limiter); n > 0 {
		slog.Info("orphan partials resumed", "n", n)
	}
	s.queue = startQueuePersister(qp, mgr)

	s.API = localapi.New(mgr, s.Token, s.Dir)
	s.API.PairFunc = s.pairFunc
	s.API.ResolveDir = s.Resolve
	if addr, err := s.API.Start(); err == nil {
		s.Addr = addr
	} else {
		slog.Error("capture endpoint failed to bind; browser hand-off disabled", "err", err)
	}
	slog.Info("started", "version", version.Version, "addr", s.Addr, "dir", s.Dir, "settings", spath, "maxConcurrent", maxConcurrent)
	go s.scheduler(ctx)
	return s, nil
}

// Stop shuts the service down: the queue is written first (running jobs are
// recorded as pending so they resume next start), then the capture endpoint
// closes and the manager is cancelled.
func (s *Service) Stop() {
	if s.API != nil {
		_ = s.API.Close()
	}
	// Stop running downloads first and wait for them: a job that finishes
	// in this window is recorded Done (not re-downloaded next start), one
	// that is interrupted is recorded pending with Resume.
	s.Mgr.Shutdown()
	if s.queue != nil {
		_ = s.queue.Close()
	}
	s.cancel()
	slog.Info("stopped")
}

// Resolve picks the folder for a download per the settings rules.
func (s *Service) Resolve(rawURL, filename string) string {
	return s.Settings.Resolve(rawURL, filename)
}

// AddWith enqueues a download described by o.
func (s *Service) AddWith(o AddOpts) (string, error) {
	if _, err := url.ParseRequestURI(o.URL); err != nil {
		return "", fmt.Errorf("invalid URL %q", o.URL)
	}
	name := FilenameFor(o.URL)
	dir := o.Dir
	if dir == "" {
		dir = s.Resolve(o.URL, name)
	}
	conns := o.Conns
	if conns <= 0 {
		conns = s.Settings.Snapshot().DefaultConns
	}
	return s.Mgr.Add(job.Spec{
		URL: o.URL, Out: filepath.Join(dir, name), Priority: o.Priority, StartAt: o.StartAt,
		Options: download.Options{Conns: conns, SHA256: o.SHA256, Resume: true, SharedLimiter: s.limiter},
	})
}

// Add enqueues a download (compat wrapper around AddWith).
func (s *Service) Add(rawURL, dir, sha256 string, conns int) (string, error) {
	return s.AddWith(AddOpts{URL: rawURL, Dir: dir, SHA256: sha256, Conns: conns})
}

// ConfigDir is the per-user folder holding settings.json; front-ends keep
// their own preference files (UI theme) next to it.
func (s *Service) ConfigDir() string { return filepath.Dir(s.settingsPath) }

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
	snap := s.Settings.Snapshot()
	s.Dir = snap.DownloadDir
	s.Mgr.SetMaxConcurrent(snap.MaxConcurrent)
	s.limiter.SetRate(s.Settings.EffectiveLimit(time.Now()))
	s.Mgr.SetStartGate(func() bool { return s.Settings.MayStart(time.Now()) }) // re-signals the loop
	slog.Info("settings applied", "dir", snap.DownloadDir, "maxConcurrent", snap.MaxConcurrent, "limit", s.limiter.Rate(), "queueWindow", snap.QueueWindow.Enabled)
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
				id, err := s.AddWith(AddOpts{URL: r.URL, Dir: r.Dir})
				slog.Info("recurring due", "id", id, "url", r.URL, "every", r.Every, "err", err)
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

// LoadOrCreateToken returns a stable capture token: SPATE_TOKEN if set, else
// one persisted under the user config dir (generated once).
func LoadOrCreateToken() string {
	if t := os.Getenv("SPATE_TOKEN"); t != "" {
		return t
	}
	cdir, err := paths.ConfigDir()
	if err != nil {
		return randToken()
	}
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
		return "spate-token"
	}
	return hex.EncodeToString(b)
}

// ResumeOrphans re-queues downloads whose .spate sidecar is still present
// under dir (searched one level of subfolders deep, for category folders),
// continuing from where they stopped. Outputs the queue already tracks are
// skipped. limiter may be nil.
func ResumeOrphans(mgr *job.Manager, dir string, limiter *download.Limiter) int {
	sidecars, _ := filepath.Glob(filepath.Join(dir, "*.spate"))
	nested, _ := filepath.Glob(filepath.Join(dir, "*", "*.spate"))
	// Sidecars written before the rename.
	oldTop, _ := filepath.Glob(filepath.Join(dir, "*.cascade"))
	oldNested, _ := filepath.Glob(filepath.Join(dir, "*", "*.cascade"))
	sidecars = append(sidecars, oldTop...)
	nested = append(nested, oldNested...)
	queued := map[string]bool{}
	for _, st := range mgr.Statuses() {
		if !st.State.Terminal() {
			queued[st.Out] = true
		}
	}
	n := 0
	for _, sc := range append(sidecars, nested...) {
		out := strings.TrimSuffix(strings.TrimSuffix(sc, ".spate"), ".cascade")
		if queued[out] {
			continue
		}
		ctrl, err := download.LoadControl(out)
		if err != nil || ctrl == nil || ctrl.URL == "" {
			continue
		}
		if !hasPartial(out, ctrl.Layout == "") {
			continue
		}
		if _, err := mgr.Add(job.Spec{URL: ctrl.URL, Out: out, Options: download.Options{Resume: true, SharedLimiter: limiter}}); err == nil {
			n++
		}
	}
	return n
}

// hasPartial reports whether partial data exists for out: the .part file,
// or, only when the sidecar predates .part naming, the output path itself.
func hasPartial(out string, legacy bool) bool {
	if _, err := os.Stat(download.PartPath(out)); err == nil {
		return true
	}
	if !legacy {
		return false
	}
	_, err := os.Stat(out)
	return err == nil
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
