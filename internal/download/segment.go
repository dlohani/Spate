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

// fetchSegment downloads segment idx, retrying transient failures. It resumes
// from the segment's recorded Done offset, so retries never re-fetch bytes
// already written.
func (d *Downloader) fetchSegment(ctx context.Context, idx int) error {
	seg := d.ctrl.Segments[idx]
	if seg.Length() == 0 {
		return nil
	}
	var lastErr error
	for attempt := 0; attempt <= d.opts.Retries; attempt++ {
		if attempt > 0 {
			if err := sleepBackoff(ctx, attempt); err != nil {
				return err
			}
		}
		d.ctrl.mu.Lock()
		done := d.ctrl.Segments[idx].Done
		d.ctrl.mu.Unlock()
		if done >= seg.Length() {
			return nil
		}
		err := d.streamSegment(ctx, idx, seg, done)
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
	return fmt.Errorf("segment %d: exhausted retries: %w", idx, lastErr)
}

func (d *Downloader) streamSegment(ctx context.Context, idx int, seg Segment, done int64) error {
	startAbs := seg.Start + done
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, d.url, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", startAbs, seg.End))
	if d.validator != "" {
		req.Header.Set("If-Range", d.validator)
	}
	resp, err := d.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	wholeFile := seg.Start == 0 && seg.End == d.ctrl.Total-1 && done == 0
	switch resp.StatusCode {
	case http.StatusPartialContent:
		// expected
	case http.StatusOK:
		if !wholeFile {
			return fmt.Errorf("segment %d: got 200 to a ranged request "+
				"(resource changed mid-download or lost range support)", idx)
		}
	default:
		if resp.StatusCode >= 500 || resp.StatusCode == http.StatusTooManyRequests {
			return &httpStatusError{code: resp.StatusCode, status: resp.Status}
		}
		return fmt.Errorf("segment %d: unexpected status %s", idx, resp.Status)
	}

	buf := make([]byte, chunkSize)
	offset := startAbs
	for {
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			if werr := d.limiter.Wait(ctx, n); werr != nil {
				return werr
			}
			if _, werr := d.file.WriteAt(buf[:n], offset); werr != nil {
				return werr
			}
			offset += int64(n)
			d.ctrl.advance(idx, int64(n))
			d.meter.Add(int64(n))
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return rerr
		}
	}

	d.ctrl.mu.Lock()
	segDone := d.ctrl.Segments[idx].Done
	d.ctrl.mu.Unlock()
	if segDone < seg.Length() {
		return io.ErrUnexpectedEOF // short read: transient, retry resumes from segDone
	}
	return nil
}

// httpStatusError marks server responses worth retrying (5xx, 429).
type httpStatusError struct {
	code   int
	status string
}

func (e *httpStatusError) Error() string {
	return fmt.Sprintf("server error: %s", e.status)
}

// isTransient reports whether err is worth retrying.
func isTransient(err error) bool {
	if err == nil {
		return false
	}
	var se *httpStatusError
	if errors.As(err, &se) {
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
	d := base << (attempt - 1)
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
