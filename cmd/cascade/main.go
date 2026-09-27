// Command cascade is a segmented, resumable HTTP downloader.
//
// It fetches a file over multiple parallel byte-range connections to make full
// use of the bandwidth the connection provides and to defeat per-connection or
// server-side throttling. It does not attempt to evade an ISP's aggregate rate
// shaping or data cap.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"cascade/internal/download"
	"cascade/internal/progress"
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	fs := flag.NewFlagSet("cascade", flag.ContinueOnError)
	var headers headerFlags
	var (
		out      = fs.String("o", "", "output file path (default: derived from URL)")
		conns    = fs.Int("n", 8, "number of parallel connections")
		resume   = fs.Bool("resume", false, "resume from an existing .cascade sidecar if present")
		limit    = fs.String("limit", "", "aggregate rate limit, e.g. 2M or 500K (default: unlimited)")
		sha      = fs.String("sha256", "", "expected SHA-256 hex digest to verify on completion")
		retries  = fs.Int("retries", 5, "per-segment retry attempts")
		cookie   = fs.String("cookie", "", "Cookie header value")
		user     = fs.String("user", "", "HTTP basic auth as user:password")
		proxy    = fs.String("proxy", "", "proxy URL, e.g. http://user:pass@host:port")
		insecure = fs.Bool("insecure", false, "skip TLS certificate verification")
	)
	fs.Var(&headers, "H", "extra request header 'Key: Value' (repeatable)")
	fs.Usage = func() {
		fmt.Fprintf(fs.Output(), "usage: cascade [flags] <url>\n\nflags:\n")
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fs.Usage()
		return 2
	}
	rawURL := fs.Arg(0)

	rate, err := parseSize(*limit)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cascade: invalid --limit: %v\n", err)
		return 2
	}
	hdrMap, err := headers.toMap()
	if err != nil {
		fmt.Fprintf(os.Stderr, "cascade: invalid -H: %v\n", err)
		return 2
	}
	var basicUser, basicPass string
	if *user != "" {
		basicUser, basicPass, _ = strings.Cut(*user, ":")
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	d := download.New(rawURL, *out, download.Options{
		Conns:         *conns,
		Retries:       *retries,
		RateLimit:     rate,
		SHA256:        *sha,
		Resume:        *resume,
		Headers:       hdrMap,
		Cookie:        *cookie,
		BasicUser:     basicUser,
		BasicPassword: basicPass,
		Proxy:         *proxy,
		Insecure:      *insecure,
	})

	done := make(chan error, 1)
	go func() { done <- d.Run(ctx) }()

	err = reportProgress(ctx, d, done)

	if err != nil {
		if errors.Is(err, context.Canceled) {
			fmt.Fprintf(os.Stderr, "\ncascade: interrupted; rerun with --resume to continue\n")
			return 130
		}
		fmt.Fprintf(os.Stderr, "\ncascade: %v\n", err)
		return 1
	}
	fmt.Fprintf(os.Stderr, "\ncascade: saved %s\n", d.Output())
	return 0
}

// reportProgress prints a live status line until the download finishes.
func reportProgress(ctx context.Context, d *download.Downloader, done <-chan error) error {
	t := time.NewTicker(1 * time.Second)
	defer t.Stop()
	for {
		select {
		case err := <-done:
			return err
		case <-t.C:
			if m := d.Meter(); m != nil {
				printLine(m)
			}
		case <-ctx.Done():
			// Wait for Run to unwind and return its (canceled) error.
			return <-done
		}
	}
}

func printLine(m *progress.Meter) {
	doneBytes, bps, eta := m.Snapshot()
	total := m.Total()
	if total > 0 {
		pct := float64(doneBytes) / float64(total) * 100
		fmt.Fprintf(os.Stderr, "\r%6.2f%%  %s / %s  %s/s  ETA %s        ",
			pct, humanBytes(doneBytes), humanBytes(total), humanBytes(int64(bps)), humanETA(eta))
	} else {
		fmt.Fprintf(os.Stderr, "\r%s  %s/s        ",
			humanBytes(doneBytes), humanBytes(int64(bps)))
	}
}

// headerFlags collects repeatable -H "Key: Value" flags.
type headerFlags []string

func (h *headerFlags) String() string { return strings.Join(*h, ", ") }

func (h *headerFlags) Set(v string) error {
	*h = append(*h, v)
	return nil
}

func (h headerFlags) toMap() (map[string]string, error) {
	if len(h) == 0 {
		return nil, nil
	}
	m := make(map[string]string, len(h))
	for _, raw := range h {
		k, v, ok := strings.Cut(raw, ":")
		if !ok {
			return nil, fmt.Errorf("header %q must be in 'Key: Value' form", raw)
		}
		m[strings.TrimSpace(k)] = strings.TrimSpace(v)
	}
	return m, nil
}

// parseSize parses a byte count with an optional K/M/G suffix (base 1024).
// An empty string returns 0 (meaning unlimited for the rate limit).
func parseSize(s string) (int64, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, nil
	}
	mult := int64(1)
	switch last := s[len(s)-1]; last {
	case 'k', 'K':
		mult = 1 << 10
		s = s[:len(s)-1]
	case 'm', 'M':
		mult = 1 << 20
		s = s[:len(s)-1]
	case 'g', 'G':
		mult = 1 << 30
		s = s[:len(s)-1]
	}
	n, err := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	if err != nil {
		return 0, err
	}
	if n < 0 {
		return 0, fmt.Errorf("negative size")
	}
	return n * mult, nil
}

func humanBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for x := n / unit; x >= unit; x /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTPE"[exp])
}

func humanETA(d time.Duration) string {
	if d <= 0 {
		return "--"
	}
	d = d.Round(time.Second)
	return d.String()
}
