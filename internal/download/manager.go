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
	"net/http"
	"net/url"
	"os"
	"path"
	"sync"
	"time"

	"cascade/internal/httpc"
	"cascade/internal/progress"
)

// Options configures a download.
type Options struct {
	Conns             int    // max parallel connections (default 8)
	MinSegment        int64  // smallest initial segment size in bytes (default 1 MiB)
	WindowSize        int64  // per-request window for windowed fetching (default 4 MiB)
	StealMinRemaining int64  // min tail to justify a work-steal split (default 2*WindowSize)
	Retries           int    // per-window retry attempts (default 5)
	RateLimit         int64  // aggregate bytes/sec, 0 = unlimited
	SHA256            string // optional expected hex digest to verify on completion
	Resume            bool   // reuse an existing .cascade sidecar if valid

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
	} else if o.Retries == 0 {
		o.Retries = 5
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
	return &Downloader{
		url:     u,
		out:     out,
		opts:    opts,
		rc:      newRequestConfig(opts),
		limiter: NewLimiter(opts.RateLimit),
	}
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
		d.out = deriveFilename(d.url, probe.Filename)
	}
	d.validator = probe.Validator()

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

	runErr := d.runWorkers(ctx)

	close(stop)
	saver.Wait()
	_ = d.ctrl.Save() // final flush regardless of outcome

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
	return d.ctrl.Remove()
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
	req, err := d.rc.newRequest(ctx, http.MethodGet, d.currentURL())
	if err != nil {
		return err
	}
	resp, err := d.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s: unexpected status %s", d.url, resp.Status)
	}

	f, err := os.OpenFile(d.out, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()

	d.setMeter(progress.New(size))
	buf := make([]byte, chunkSize)
	for {
		n, rerr := resp.Body.Read(buf)
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
	return verifySHA256(d.out, d.opts.SHA256)
}

// deriveFilename picks an output name from a Content-Disposition suggestion or
// the URL path, defaulting to download.bin.
func deriveFilename(rawURL, suggested string) string {
	if suggested != "" {
		return suggested
	}
	if u, err := url.Parse(rawURL); err == nil {
		if base := path.Base(u.Path); base != "" && base != "/" && base != "." {
			return base
		}
	}
	return "download.bin"
}
