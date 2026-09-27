package download

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"syscall"
	"time"
)

// PlanSegments splits a file of total bytes into contiguous ranges. It creates
// at most conns segments, and never a segment smaller than minSeg (except when
// the file itself is smaller). For total <= 0 it returns a single empty segment.
func PlanSegments(total int64, conns int, minSeg int64) []Segment {
	if total <= 0 {
		return []Segment{{Index: 0, Start: 0, End: -1}} // Length()==0
	}
	if conns < 1 {
		conns = 1
	}
	if minSeg < 1 {
		minSeg = 1
	}
	maxByMin := total / minSeg
	if maxByMin < 1 {
		maxByMin = 1
	}
	nseg := int64(conns)
	if nseg > maxByMin {
		nseg = maxByMin
	}
	base := total / nseg
	rem := total % nseg
	segs := make([]Segment, 0, nseg)
	var start int64
	for i := int64(0); i < nseg; i++ {
		size := base
		if i < rem {
			size++
		}
		end := start + size - 1
		segs = append(segs, Segment{Index: int(i), Start: start, End: end})
		start = end + 1
	}
	return segs
}

// fetchPiece downloads segment idx in bounded windows, re-reading the segment's
// end between windows so a concurrent steal (which shrinks End) takes effect at
// the next window boundary rather than being over-fetched.
func (d *Downloader) fetchPiece(ctx context.Context, idx int) error {
	window := d.opts.WindowSize
	for {
		d.ctrl.mu.Lock()
		s := d.ctrl.Segments[idx]
		d.ctrl.mu.Unlock()

		absCur := s.Start + s.Done
		if absCur > s.End {
			return nil // segment complete, or its tail was stolen away
		}
		end := absCur + window - 1
		if end > s.End {
			end = s.End
		}
		if err := d.fetchWindow(ctx, idx, absCur, end); err != nil {
			return err
		}
	}
}

// IsTransient reports whether err (possibly wrapped) is a retryable network or
// server condition, e.g. a connection reset, a corrupted TLS record, a short
// read, or a 5xx/429. Callers (the job manager) use it to decide whether a
// failed download is worth re-queuing rather than declaring it broken.
func IsTransient(err error) bool { return isTransient(err) }

// fetchWindow downloads the byte range [start, end] of segment idx, retrying
// transient failures and resuming from the segment's advanced Done offset so no
// byte is fetched twice. With Retries > 0 it makes that many extra attempts;
// with Retries == 0 it keeps retrying (backoff capped at 10s) for RetryFor.
func (d *Downloader) fetchWindow(ctx context.Context, idx int, start, end int64) error {
	var lastErr error
	began := time.Now()
	for attempt := 0; ; attempt++ {
		if attempt > 0 {
			if d.opts.Retries > 0 && attempt > d.opts.Retries {
				break
			}
			if d.opts.Retries == 0 && time.Since(began) > d.opts.RetryFor {
				break
			}
			if err := sleepBackoff(ctx, attempt); err != nil {
				return err
			}
		}
		d.ctrl.mu.Lock()
		s := d.ctrl.Segments[idx]
		d.ctrl.mu.Unlock()
		from := s.Start + s.Done
		if from > end {
			return nil // window already satisfied by a prior partial attempt
		}
		err := d.streamRange(ctx, idx, from, end)
		if err == nil {
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if !isTransient(err) {
			return err
		}
		lastErr = err
	}
	return fmt.Errorf("segment %d [%d-%d]: exhausted retries: %w", idx, start, end, lastErr)
}

// streamRange performs one ranged GET for [from, end] and writes it at offset.
func (d *Downloader) streamRange(ctx context.Context, idx int, from, end int64) error {
	usedURL := d.currentURL()
	req, err := d.rc.newRequest(ctx, http.MethodGet, usedURL)
	if err != nil {
		return err
	}
	req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", from, end))
	if d.validator != "" {
		req.Header.Set("If-Range", d.validator)
	}

	// Take a connection slot; the limit shrinks if the host refuses extras.
	if err := d.conns.acquire(ctx); err != nil {
		return err
	}
	released := false
	defer func() {
		if !released {
			d.conns.release()
		}
	}()

	resp, err := d.client.Do(req)
	if err != nil {
		return &netError{err} // dial/handshake/TLS error: retry on a fresh connection
	}
	defer resp.Body.Close()

	switch resp.StatusCode {
	case http.StatusPartialContent:
		// expected
	case http.StatusOK:
		return fmt.Errorf("segment %d: got 200 to a ranged request "+
			"(resource changed mid-download or lost range support)", idx)
	case http.StatusServiceUnavailable, http.StatusTooManyRequests:
		// The host allows fewer simultaneous connections than we opened:
		// shrink to what is streaming and retry later on a free slot.
		d.conns.refused()
		released = true
		return &httpStatusError{code: resp.StatusCode, status: resp.Status}
	case http.StatusUnauthorized, http.StatusForbidden, http.StatusGone:
		// URL may have expired; try to refresh it and retry.
		if d.opts.RefreshURL == nil {
			return fmt.Errorf("segment %d: %s (no RefreshURL configured)", idx, resp.Status)
		}
		if err := d.refresh(ctx, usedURL); err != nil {
			return fmt.Errorf("segment %d: URL refresh after %s failed: %w", idx, resp.Status, err)
		}
		return errURLRefreshed
	default:
		if resp.StatusCode >= 500 || resp.StatusCode == http.StatusTooManyRequests {
			return &httpStatusError{code: resp.StatusCode, status: resp.Status}
		}
		return fmt.Errorf("segment %d: unexpected status %s", idx, resp.Status)
	}

	want := end - from + 1
	var got int64
	offset := from
	buf := make([]byte, chunkSize)
	for {
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			// Never write past the requested window, even if the server sends more.
			if got+int64(n) > want {
				n = int(want - got)
			}
			if werr := d.limiter.Wait(ctx, n); werr != nil {
				return werr
			}
			if _, werr := d.file.WriteAt(buf[:n], offset); werr != nil {
				return werr
			}
			offset += int64(n)
			got += int64(n)
			d.ctrl.advance(idx, int64(n))
			d.meter.Add(int64(n))
			if got >= want {
				break
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return &netError{rerr} // read error mid-body (incl. TLS bad record MAC): retry
		}
	}
	if got < want {
		return io.ErrUnexpectedEOF // short read: transient, retry resumes from advanced Done
	}
	return nil
}

// errURLRefreshed signals that the download URL was rotated and the request
// should be retried against the new URL. It is treated as transient.
var errURLRefreshed = errors.New("download URL refreshed; retry")

// httpStatusError marks server responses worth retrying (5xx, 429).
type httpStatusError struct {
	code   int
	status string
}

func (e *httpStatusError) Error() string {
	return fmt.Sprintf("server error: %s", e.status)
}

// netError marks a network-level failure (dial, TLS handshake, or a read error
// mid-body such as "tls: bad record MAC" from a corrupted/tampered record) as
// retryable: a fresh connection usually succeeds and progress resumes via Range.
type netError struct{ err error }

func (e *netError) Error() string { return e.err.Error() }
func (e *netError) Unwrap() error { return e.err }

// isTransient reports whether err is worth retrying.
func isTransient(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, errURLRefreshed) {
		return true
	}
	var se *httpStatusError
	if errors.As(err, &se) {
		return true
	}
	var ne2 *netError
	if errors.As(err, &ne2) {
		return true
	}
	if errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, io.EOF) {
		return true
	}
	if errors.Is(err, syscall.ECONNRESET) || errors.Is(err, syscall.EPIPE) ||
		errors.Is(err, syscall.ECONNABORTED) || errors.Is(err, syscall.ETIMEDOUT) {
		return true
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return true
	}
	return false
}

// sleepBackoff waits an exponentially growing, jittered interval before the
// next attempt, or returns early if ctx is cancelled.
func sleepBackoff(ctx context.Context, attempt int) error {
	const base = 300 * time.Millisecond
	const max = 10 * time.Second
	shift := attempt - 1
	if shift > 6 { // 300ms<<6 already exceeds max; avoid overflow on long retry runs
		shift = 6
	}
	d := base << shift
	if d > max {
		d = max
	}
	// full jitter in [d/2, d]
	half := d / 2
	d = half + time.Duration(rand.Int63n(int64(half)+1))
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
