package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLastErrorAfterFailedStart(t *testing.T) {
	t.Setenv("CASCADE_TOKEN", "test-token")
	dir := t.TempDir()
	sp := filepath.Join(dir, "settings.json")
	if err := os.WriteFile(sp, []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	if h := startJSON(fmt.Sprintf(`{"settingsPath":%q,"downloadDir":%q,"allowMultiple":true}`, sp, dir)); h != 0 {
		t.Fatal("expected start to fail on a corrupt settings file")
	}
	if msg := lastErrorText(); !strings.Contains(msg, "settings") {
		t.Fatalf("last error = %q, want the settings parse error", msg)
	}
	// A successful start clears it.
	if err := os.Remove(sp); err != nil {
		t.Fatal(err)
	}
	h := startJSON(fmt.Sprintf(`{"settingsPath":%q,"downloadDir":%q,"allowMultiple":true}`, sp, dir))
	if h == 0 {
		t.Fatalf("start failed: %s", lastErrorText())
	}
	defer stopID(h)
	if msg := lastErrorText(); msg != "" {
		t.Fatalf("last error not cleared: %q", msg)
	}
	if v := lookupID(h).Mgr.Version(); v == 0 {
		t.Fatal("queue version should be non-zero")
	}
}
