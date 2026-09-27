package download

import (
	"context"
	"sync"
	"time"
)

// connLimiter adapts the number of simultaneous connections to what the server
// tolerates. Free-tier file hosts often allow one download connection per IP
// and answer 503/429 to any extra; without adaptation, N segment workers would
// keep colliding. When a worker is refused, the limit shrinks to the number of
// connections that are actually streaming (at least 1), and other workers wait
// for a slot instead of hammering the host.
type connLimiter struct {
	mu     sync.Mutex
	max    int
	active int
}

func newConnLimiter(max int) *connLimiter {
	if max < 1 {
		max = 1
	}
	return &connLimiter{max: max}
}

// acquire blocks until a connection slot is free or ctx is done.
func (l *connLimiter) acquire(ctx context.Context) error {
	for {
		l.mu.Lock()
		if l.active < l.max {
			l.active++
			l.mu.Unlock()
			return nil
		}
		l.mu.Unlock()
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(150 * time.Millisecond):
		}
	}
}

// release frees a slot.
func (l *connLimiter) release() {
	l.mu.Lock()
	if l.active > 0 {
		l.active--
	}
	l.mu.Unlock()
}

// refused records that the server rejected this connection (503/429) and
// releases its slot: the limit drops to the connections still streaming.
func (l *connLimiter) refused() {
	l.mu.Lock()
	if l.active > 0 {
		l.active--
	}
	if l.active >= 1 {
		l.max = l.active
	} else {
		l.max = 1
	}
	l.mu.Unlock()
}

// limit returns the current maximum (diagnostics/tests).
func (l *connLimiter) limit() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.max
}
