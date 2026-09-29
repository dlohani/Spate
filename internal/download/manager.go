// Package download implements a segmented, resumable HTTP download engine.
//
// The engine opens multiple parallel byte-range connections to fetch one file,
// writing each range at its offset in a single preallocated output file, and
// persists per-segment progress so an interrupted transfer can resume. This
// saturates the bandwidth the link provides and defeats per-connection or
// server-side throttling; it does not evade an ISP's aggregate rate shaping or
// data cap.
package download

import (
	"context"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"

	"cascade/internal/httpc"
	"cascade/internal/progress"
)

// Options configures a download.
type Options struct {
	Conns             int           // max parallel connections (default 8)
	MinSegment        int64         // smallest initial segment size in bytes (default 1 MiB)
	WindowSize        int64         // per-request window for windowed fetching (default 4 MiB)
	StealMinRemaining int64         // min tail to justify a work-steal split (default 2*WindowSize)
	Retries           int           // per-window extra attempts; 0 = keep retrying for RetryFor
	RetryFor          time.Duration // how long a window keeps retrying when Retries == 0 (default 15m)
	RateLimit         int64         // this download's cap in bytes/sec, 0 = unlimited
	SharedLimiter     *Limiter      // if set, a limiter shared across downloads (global cap); overrides RateLimit
	SHA256            string        // optional expected hex digest to verify on completion
	Resume            bool          // reuse an existing .cascade sidecar if valid
	ExtractTo         string        // if set, extract a downloaded archive into this dir

	// Request customization.
	Headers       map[string]string // extra request headers
	Cookie        string            // raw Cookie header value
	BasicUser     string            // HTTP Basic auth username
	BasicPassword string            // HTTP Basic auth password
	Proxy         string            // explicit proxy URL (else HTTP(S)_PROXY)
	Insecure      bool              // skip TLS verification

	// RefreshURL, when set, is called to obtain a fresh download URL if the
	// current one is rejected as expired (HTTP 401/403/410) mid-download.
	RefreshURL func(ctx context.Context, old string) (string, error)

	// Gate, when set, is polled before and during the download; if it returns
	// false the download is blocked or paused (used for Wi-Fi-only / battery
	// policies). Run then returns a *GateError.
	Gate GateFunc
	// GatePollInterval is how often Gate is re-checked mid-download (default 3s).
	GatePollInterval time.Duration
}

func (o *Options) setDefaults() {
	if o.Conns <= 0 {
		o.Conns = 8
	}
	if o.MinSegment <= 0 {
		o.MinSegment = 1 << 20 // 1 MiB
	}
	if o.WindowSize <= 0 {
		o.WindowSize = 4 << 20 // 4 MiB
	}
	// A steal must leave the victim's in-flight window untouched, so the split
	// point is guaranteed to sit beyond it: require at least two windows.
	if o.StealMinRemaining < 2*o.WindowSize {
		o.StealMinRemaining = 2 * o.WindowSize
	}
	if o.Retries < 0 {
		o.Retries = 0
	}
	if o.RetryFor <= 0 {
		o.RetryFor = 15 * time.Minute
	}
}

// Downloader coordinates one download.
type Downloader struct {
	url  string
	out  string
	opts Options

	client    *http.Client
	rc        requestConfig
	file      *os.File
	ctrl      *Control
	meter     *progress.Meter
	limiter   *Limiter
	conns     *connLimiter // adapts parallelism to what the host tolerates
	validator string

	mu sync.Mutex // guards url (mutable when RefreshURL rotates it)
}

// currentURL returns the (possibly refreshed) download URL.
func (d *Downloader) currentURL() string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.url
}

// refresh rotates the download URL via Options.RefreshURL, but only if it hasn't
// already been rotated away from stale by another worker (so concurrent 403s
// trigger at most one refresh per stale URL).
func (d *Downloader) refresh(ctx context.Context, stale string) error {
	d.mu.Lock()
	already := d.url != stale
	fn := d.opts.RefreshURL
	d.mu.Unlock()
	if already {
		return nil
	}
	if fn == nil {
		return errors.New("no RefreshURL configured")
	}
	newURL, err := fn(ctx, stale)
	if err != nil {
		return err
	}
	if newURL == "" {
		return errors.New("RefreshURL returned an empty URL")
	}
	d.mu.Lock()
	if d.url == stale {
		d.url = newURL
	}
	d.mu.Unlock()
	return nil
}

// New builds a Downloader for url. out may be empty, in which case a filename is
// derived from the URL (or the server's Content-Disposition) during Run.
func New(u, out string, opts Options) *Downloader {
	opts.setDefaults()
	d := &Downloader{
		url:     u,
		out:     out,
		opts:    opts,
		rc:      newRequestConfig(opts),
		limiter: NewLimiter(opts.RateLimit),
		conns:   newConnLimiter(opts.Conns),
	}
	if opts.SharedLimiter != nil {
		d.limiter = opts.SharedLimiter // global cap shared by all downloads
	}
	return d
}

// Meter exposes live progress; valid after Run has begun. May be nil before.
// Safe to call from another goroutine (e.g. a status poller).
func (d *Downloader) Meter() *progress.Meter {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.meter
}

func (d *Downloader) setMeter(m *progress.Meter) {
	d.mu.Lock()
	d.meter = m
	d.mu.Unlock()
}

// Output returns the resolved output path (valid after Run resolves it).
func (d *Downloader) Output() string { return d.out }

// Run executes the download to completion or returns an error. On error or
// cancellation the partial file and its .cascade sidecar are left in place so a
// later Run with Resume can continue.
func (d *Downloader) Run(ctx context.Context) error {
	client, err := httpc.New(httpc.Config{
		MaxConns: d.opts.Conns,
		Proxy:    d.opts.Proxy,
		Insecure: d.opts.Insecure,
	})
	if err != nil {
		return err
	}
	d.client = client

	probe, err := Probe(ctx, d.client, d.rc, d.currentURL())
	if err != nil {
		return err
	}
	if d.out == "" {
		d.out = deriveFilename(d.currentURL(), probe.Filename, probe.ContentType)
	}
	d.validator = probe.Validator()

	if ge := d.gateOpen(); ge != nil {
		return ge
	}

	// Unknown size or no range support: fall back to a single stream.
	if probe.Size < 0 || !probe.AcceptRanges {
		return d.streamWhole(ctx, probe.Size)
	}

	if err := d.prepare(ctx, probe); err != nil {
		return err
	}
	defer d.file.Close()

	meter := progress.New(probe.Size)
	// Account for bytes already on disk from a resumed run.
	meter.Add(d.ctrl.BytesDone())
	d.setMeter(meter)

	// Persist resume state periodically while workers run.
	stop := make(chan struct{})
	var saver sync.WaitGroup
	saver.Add(1)
	go func() {
		defer saver.Done()
		t := time.NewTicker(2 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-stop:
				return
			case <-t.C:
				_ = d.ctrl.Save()
			}
		}
	}()

	gctx, gateCheck, gateStop := d.gateContext(ctx)
	defer gateStop()

	runErr := d.runWorkers(gctx)

	close(stop)
	saver.Wait()
	_ = d.ctrl.Save() // final flush regardless of outcome

	if ge := gateCheck(); ge != nil {
		return ge // policy closed mid-download; state is saved for resume
	}
	if runErr != nil {
		return runErr
	}
	if !d.ctrl.AllComplete() {
		return fmt.Errorf("download incomplete: %d of %d bytes", d.ctrl.BytesDone(), probe.Size)
	}
	if err := d.file.Sync(); err != nil {
		return err
	}
	if err := verifySHA256(d.out, d.opts.SHA256); err != nil {
		return err
	}
	if err := d.ctrl.Remove(); err != nil {
		return err
	}
	return d.postProcess()
}

// CheckFetchable probes u with the same client and request customization a
// download would use and returns an error if the server refuses (e.g. 403 on a
// session-bound or POST-only URL). Callers use it to reject a hand-off before
// the browser's own download is cancelled, so nothing is lost.
func CheckFetchable(ctx context.Context, u string, opts Options) error {
	opts.setDefaults()
	client, err := httpc.New(httpc.Config{MaxConns: 1, Proxy: opts.Proxy, Insecure: opts.Insecure})
	if err != nil {
		return err
	}
	_, err = Probe(ctx, client, newRequestConfig(opts), u)
	return err
}

// gateOpen returns a *GateError if the policy currently forbids downloading.
func (d *Downloader) gateOpen() *GateError {
	if d.opts.Gate == nil {
		return nil
	}
	if ok, reason := d.opts.Gate(); !ok {
		return &GateError{Reason: reason}
	}
	return nil
}

// gateContext returns a context that is cancelled if the policy gate closes
// while the download runs, a check that reports the closure reason afterward,
// and a stop func to release the monitor.
func (d *Downloader) gateContext(ctx context.Context) (context.Context, func() *GateError, func()) {
	if d.opts.Gate == nil {
		return ctx, func() *GateError { return nil }, func() {}
	}
	interval := d.opts.GatePollInterval
	if interval <= 0 {
		interval = 3 * time.Second
	}
	gctx, cancel := context.WithCancel(ctx)
	var reason atomic.Value
	done := make(chan struct{})
	go func() {
		t := time.NewTicker(interval)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-gctx.Done():
				return
			case <-t.C:
				if ok, r := d.opts.Gate(); !ok {
					reason.Store(r)
					cancel()
					return
				}
			}
		}
	}()
	check := func() *GateError {
		if r, ok := reason.Load().(string); ok && r != "" {
			return &GateError{Reason: r}
		}
		return nil
	}
	var once sync.Once
	stop := func() { once.Do(func() { close(done); cancel() }) }
	return gctx, check, stop
}

// postProcess runs any configured after-download step (currently extraction).
func (d *Downloader) postProcess() error {
	if d.opts.ExtractTo == "" {
		return nil
	}
	return extractArchive(d.out, d.opts.ExtractTo)
}

// prepare resolves resume state and opens/preallocates the output file.
func (d *Downloader) prepare(ctx context.Context, probe ProbeResult) error {
	if d.opts.Resume {
		existing, err := LoadControl(d.out)
		if err != nil {
			return err
		}
		if existing != nil && d.canResume(existing, probe) {
			f, err := os.OpenFile(d.out, os.O_RDWR, 0o644)
			if err != nil {
				return fmt.Errorf("resume: reopen output: %w", err)
			}
			d.file = f
			d.ctrl = existing
			return nil
		}
		// Stale or mismatched sidecar: discard and start fresh.
		if existing != nil {
			_ = existing.Remove()
		}
	}

	// Destination folders may not exist yet (category / per-site rules).
	if err := os.MkdirAll(filepath.Dir(d.out), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(d.out, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if err := f.Truncate(probe.Size); err != nil {
		f.Close()
		return fmt.Errorf("preallocate %d bytes: %w", probe.Size, err)
	}
	d.file = f
	segs := PlanSegments(probe.Size, d.opts.Conns, d.opts.MinSegment)
	d.ctrl = NewControl(d.out, probe.FinalURL, probe.Size, probe.Validator(), segs)
	return d.ctrl.Save()
}

// canResume reports whether existing sidecar state matches the current probe.
func (d *Downloader) canResume(existing *Control, probe ProbeResult) bool {
	if existing.Total != probe.Size {
		return false
	}
	// If either side has a validator, they must match; a changed validator means
	// the upstream file changed and the partial data can't be trusted.
	if probe.Validator() != "" || existing.Validator != "" {
		if existing.Validator != probe.Validator() {
			return false
		}
	}
	if _, err := os.Stat(d.out); err != nil {
		return false // partial output gone
	}
	return true
}

// runWorkers runs a fixed pool of Conns workers. Each pulls a segment from the
// scheduler, downloads it, then pulls again; when no unassigned work remains a
// free worker steals the largest active tail (see Control.nextWork). The first
// fatal error cancels the rest.
func (d *Downloader) runWorkers(ctx context.Context) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	stealMin := d.opts.StealMinRemaining
	var wg sync.WaitGroup
	var mu sync.Mutex
	var firstErr error
	fail := func(err error) {
		mu.Lock()
		if firstErr == nil {
			firstErr = err
			cancel()
		}
		mu.Unlock()
	}

	for w := 0; w < d.opts.Conns; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				if ctx.Err() != nil {
					fail(ctx.Err())
					return
				}
				idx, ok := d.ctrl.nextWork(stealMin)
				if !ok {
					return // no more work worth doing
				}
				err := d.fetchPiece(ctx, idx)
				d.ctrl.finish(idx)
				if err != nil {
					fail(err)
					return
				}
			}
		}()
	}
	wg.Wait()
	return firstErr
}

// Splits reports how many work-steal splits occurred during the run.
func (d *Downloader) Splits() int {
	if d.ctrl == nil {
		return 0
	}
	return d.ctrl.Splits()
}

// streamWhole downloads the entire body over a single connection. Used when the
// server has no range support or the size is unknown; not resumable.
func (d *Downloader) streamWhole(ctx context.Context, size int64) error {
	var body io.ReadCloser
	if isFTP(d.currentURL()) {
		b, err := ftpOpen(ctx, d.currentURL(), 0, d.opts)
		if err != nil {
			return err
		}
		body = b
	} else {
		req, err := d.rc.newRequest(ctx, http.MethodGet, d.currentURL())
		if err != nil {
			return err
		}
		resp, err := d.client.Do(req)
		if err != nil {
			return err
		}
		if resp.StatusCode != http.StatusOK {
			resp.Body.Close()
			return fmt.Errorf("GET %s: unexpected status %s", d.url, resp.Status)
		}
		body = resp.Body
	}
	defer body.Close()

	if err := os.MkdirAll(filepath.Dir(d.out), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(d.out, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()

	d.setMeter(progress.New(size))
	buf := make([]byte, chunkSize)
	for {
		n, rerr := body.Read(buf)
		if n > 0 {
			if werr := d.limiter.Wait(ctx, n); werr != nil {
				return werr
			}
			if _, werr := f.Write(buf[:n]); werr != nil {
				return werr
			}
			d.meter.Add(int64(n))
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return rerr
		}
	}
	if err := f.Sync(); err != nil {
		return err
	}
	if err := verifySHA256(d.out, d.opts.SHA256); err != nil {
		return err
	}
	return d.postProcess()
}

// deriveFilename picks an output name from a Content-Disposition suggestion or
// the URL path, defaulting to download.bin. When the chosen name has no
// extension, one is inferred from the Content-Type.
func deriveFilename(rawURL, suggested, contentType string) string {
	if suggested != "" {
		return suggested
	}
	name := "download"
	if u, err := url.Parse(rawURL); err == nil {
		if base := path.Base(u.Path); base != "" && base != "/" && base != "." {
			name = base
		}
	}
	if path.Ext(name) == "" {
		if ext := extensionForType(contentType); ext != "" {
			name += ext
		} else if name == "download" {
			name += ".bin"
		}
	}
	return name
}

// extensionForType returns a file extension (with dot) for a Content-Type, or ""
// when none is known or the type is generic.
func extensionForType(contentType string) string {
	if contentType == "" {
		return ""
	}
	mt, _, err := mime.ParseMediaType(contentType)
	if err != nil || mt == "application/octet-stream" {
		return ""
	}
	// Prefer common, stable extensions over mime's sometimes-odd first choice.
	switch mt {
	case "application/zip":
		return ".zip"
	case "application/json":
		return ".json"
	case "text/plain":
		return ".txt"
	case "application/pdf":
		return ".pdf"
	}
	if exts, _ := mime.ExtensionsByType(mt); len(exts) > 0 {
		return exts[0]
	}
	return ""
}
