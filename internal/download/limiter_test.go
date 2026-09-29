package download

import (
	"context"
	"testing"
	"time"
)

func TestSharedLimiterSetRate(t *testing.T) {
	l := NewSharedLimiter()
	if l.Rate() != 0 {
		t.Fatal("shared limiter should start unlimited")
	}
	start := time.Now()
	for i := 0; i < 50; i++ {
		if err := l.Wait(context.Background(), 1<<20); err != nil {
			t.Fatal(err)
		}
	}
	if time.Since(start) > 50*time.Millisecond {
		t.Fatal("unlimited limiter must not block")
	}

	// 1 MiB/s: after the initial burst, 3 MiB more should take about 3s.
	l.SetRate(1 << 20)
	if l.Rate() != 1<<20 {
		t.Fatalf("rate = %d", l.Rate())
	}
	_ = l.Wait(context.Background(), 1<<20) // consume the burst
	start = time.Now()
	for i := 0; i < 3; i++ {
		_ = l.Wait(context.Background(), 1<<20)
	}
	if d := time.Since(start); d < 2500*time.Millisecond || d > 4500*time.Millisecond {
		t.Fatalf("expected ~3s for 3 MiB at 1 MiB/s, took %v", d)
	}

	// Back to unlimited: an in-flight wait releases promptly.
	l.SetRate(1 << 10) // very slow
	done := make(chan struct{})
	go func() { _ = l.Wait(context.Background(), 1<<20); close(done) }()
	time.Sleep(100 * time.Millisecond)
	l.SetRate(0)
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("wait did not release after SetRate(0)")
	}
}
