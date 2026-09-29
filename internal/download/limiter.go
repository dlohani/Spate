package download

import (
	"context"
	"sync"
	"time"
)

// Limiter is a simple shared token bucket used to optionally cap the aggregate
// transfer rate across all segment workers. It exists to be a courteous
// consumer of a shared link, not to circumvent any network control.
//
// A nil *Limiter is valid and imposes no limit.
type Limiter struct {
	mu       sync.Mutex
	rate     float64 // tokens (bytes) per second
	burst    float64 // max bucket size
	tokens   float64
	lastFill time.Time
}

// NewLimiter returns a Limiter allowing bytesPerSec bytes/second. A rate <= 0
// returns nil (unlimited).
func NewLimiter(bytesPerSec int64) *Limiter {
	if bytesPerSec <= 0 {
		return nil
	}
	r := float64(bytesPerSec)
	return &Limiter{
		rate:     r,
		burst:    r, // allow up to one second of burst
		tokens:   r,
		lastFill: time.Now(),
	}
}

// NewSharedLimiter returns a non-nil limiter that is initially unlimited and
// can be shared by every download; SetRate changes it at any time (used for
// a global cap and scheduled limit windows).
func NewSharedLimiter() *Limiter {
	return &Limiter{lastFill: time.Now()}
}

// SetRate changes the cap in bytes/sec; <= 0 means unlimited.
func (l *Limiter) SetRate(bytesPerSec int64) {
	if l == nil {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if bytesPerSec <= 0 {
		l.rate, l.burst, l.tokens = 0, 0, 0
		return
	}
	r := float64(bytesPerSec)
	l.rate, l.burst = r, r
	if l.tokens > r {
		l.tokens = r
	}
	l.lastFill = time.Now()
}

// Rate returns the current cap (0 = unlimited).
func (l *Limiter) Rate() int64 {
	if l == nil {
		return 0
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	return int64(l.rate)
}

// Wait blocks until n tokens are available or ctx is done. A nil or unlimited
// Limiter returns immediately.
func (l *Limiter) Wait(ctx context.Context, n int) error {
	if l == nil || n <= 0 {
		return nil
	}
	l.mu.Lock()
	unlimited := l.rate <= 0
	l.mu.Unlock()
	if unlimited {
		return nil
	}
	need := float64(n)
	if need > l.burst {
		need = l.burst // never wait for more than the bucket can ever hold
	}
	for {
		l.mu.Lock()
		if l.rate <= 0 { // became unlimited while waiting
			l.mu.Unlock()
			return nil
		}
		if need > l.burst {
			need = l.burst
		}
		now := time.Now()
		l.tokens += l.rate * now.Sub(l.lastFill).Seconds()
		if l.tokens > l.burst {
			l.tokens = l.burst
		}
		l.lastFill = now
		if l.tokens >= need {
			l.tokens -= need
			l.mu.Unlock()
			return nil
		}
		deficit := need - l.tokens
		wait := time.Duration(deficit / l.rate * float64(time.Second))
		l.mu.Unlock()

		if wait < time.Millisecond {
			wait = time.Millisecond
		}
		timer := time.NewTimer(wait)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}
