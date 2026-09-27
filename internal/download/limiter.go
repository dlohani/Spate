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

// Wait blocks until n tokens are available or ctx is done. A nil Limiter
// returns immediately.
func (l *Limiter) Wait(ctx context.Context, n int) error {
	if l == nil || n <= 0 {
		return nil
	}
	need := float64(n)
	if need > l.burst {
		need = l.burst // never wait for more than the bucket can ever hold
	}
	for {
		l.mu.Lock()
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
