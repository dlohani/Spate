// Package progress tracks aggregate download progress and speed.
package progress

import (
	"sync"
	"sync/atomic"
	"time"
)

// Meter accumulates bytes transferred and computes an EWMA speed estimate.
// It is safe for concurrent use by multiple segment workers.
type Meter struct {
	total int64 // total expected bytes; 0 if unknown

	done atomic.Int64 // bytes written so far

	mu        sync.Mutex
	lastTime  time.Time
	lastBytes int64
	ewmaBps   float64 // exponentially weighted bytes/sec
	start     time.Time
}

// New returns a Meter for a transfer of total bytes (0 = unknown size).
func New(total int64) *Meter {
	now := time.Now()
	return &Meter{total: total, lastTime: now, start: now}
}

// Add records n freshly transferred bytes.
func (m *Meter) Add(n int64) {
	if n > 0 {
		m.done.Add(n)
	}
}

// Done returns the total bytes transferred so far.
func (m *Meter) Done() int64 { return m.done.Load() }

// Total returns the expected total (0 if unknown).
func (m *Meter) Total() int64 { return m.total }

// Snapshot returns bytes done, instantaneous EWMA speed (bytes/sec), and ETA.
// ETA is zero when the total or speed is unknown. Call it on a fixed cadence
// (e.g. once per second) so the EWMA has a stable sampling interval.
func (m *Meter) Snapshot() (done int64, bps float64, eta time.Duration) {
	done = m.done.Load()

	m.mu.Lock()
	defer m.mu.Unlock()

	now := time.Now()
	dt := now.Sub(m.lastTime).Seconds()
	if dt > 0 {
		sampleBps := float64(done-m.lastBytes) / dt
		const alpha = 0.3
		if m.ewmaBps == 0 {
			m.ewmaBps = sampleBps
		} else {
			m.ewmaBps = alpha*sampleBps + (1-alpha)*m.ewmaBps
		}
		m.lastTime = now
		m.lastBytes = done
	}
	bps = m.ewmaBps

	if m.total > 0 && bps > 0 {
		remaining := m.total - done
		if remaining < 0 {
			remaining = 0
		}
		eta = time.Duration(float64(remaining)/bps) * time.Second
	}
	return done, bps, eta
}
