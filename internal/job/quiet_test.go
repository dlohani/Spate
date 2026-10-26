package job

import (
	"log/slog"
	"os"
	"testing"

	"spate/internal/logx"
)

// The core logs through slog's default logger, which only the service and the
// CLI configure; in tests it would otherwise print to stderr.
func TestMain(m *testing.M) {
	slog.SetDefault(logx.Discard())
	os.Exit(m.Run())
}
