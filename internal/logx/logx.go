// Package logx configures the core's logger. The core logs through
// log/slog's default logger; the service points it at a file under the
// config folder, the CLI silences it unless asked (-v). Nothing in the core
// ever writes to stdout or stderr on its own.
package logx

import (
	"io"
	"log/slog"
	"os"
)

// ToFile returns an Info-level text logger appending to path (created 0600).
// When the file is already larger than maxBytes it is first rotated to
// path+".1" (replacing any older rotation), so the log stays bounded at
// roughly two times maxBytes without a background rotator.
func ToFile(path string, maxBytes int64) (*slog.Logger, error) {
	if fi, err := os.Stat(path); err == nil && maxBytes > 0 && fi.Size() > maxBytes {
		if err := os.Rename(path, path+".1"); err != nil {
			return nil, err
		}
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	return slog.New(slog.NewTextHandler(f, &slog.HandlerOptions{Level: slog.LevelInfo})), nil
}

// Discard returns a logger that drops everything.
func Discard() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError + 1}))
}

// Stderr returns an Info-level text logger on stderr (the CLI's -v).
func Stderr() *slog.Logger {
	return slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
}
