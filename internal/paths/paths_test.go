package paths

import (
	"os"
	"path/filepath"
	"testing"
)

func TestConfigDirMigratesLegacyFiles(t *testing.T) {
	base := t.TempDir()
	old := filepath.Join(base, legacyName)
	os.MkdirAll(filepath.Join(old, "bin"), 0o700)
	for _, f := range []string{"settings.json", "token", "queue.json", "ui.json"} {
		os.WriteFile(filepath.Join(old, f), []byte("old "+f), 0o600)
	}
	os.WriteFile(filepath.Join(old, "bin", "cascade-host"), []byte("bin"), 0o700)

	dir, err := ConfigDirIn(base)
	if err != nil {
		t.Fatal(err)
	}
	if dir != filepath.Join(base, Name) {
		t.Fatalf("dir = %s", dir)
	}
	for _, f := range []string{"settings.json", "token", "queue.json", "ui.json"} {
		b, err := os.ReadFile(filepath.Join(dir, f))
		if err != nil || string(b) != "old "+f {
			t.Fatalf("%s not migrated: %q %v", f, b, err)
		}
		if _, err := os.Stat(filepath.Join(old, f)); err == nil {
			t.Fatalf("%s left behind in the legacy folder", f)
		}
	}
	if _, err := os.Stat(filepath.Join(old, "bin", "cascade-host")); err != nil {
		t.Fatal("binaries must stay where the old installer put them (its uninstaller removes them)")
	}
}

func TestConfigDirNeverOverwritesNewFiles(t *testing.T) {
	base := t.TempDir()
	os.MkdirAll(filepath.Join(base, legacyName), 0o700)
	os.WriteFile(filepath.Join(base, legacyName, "settings.json"), []byte("old"), 0o600)
	os.MkdirAll(filepath.Join(base, Name), 0o700)
	os.WriteFile(filepath.Join(base, Name, "settings.json"), []byte("new"), 0o600)
	dir, _ := ConfigDirIn(base)
	b, _ := os.ReadFile(filepath.Join(dir, "settings.json"))
	if string(b) != "new" {
		t.Fatalf("new settings overwritten: %q", b)
	}
}

func TestConfigDirFreshInstall(t *testing.T) {
	base := t.TempDir()
	dir, err := ConfigDirIn(base)
	if err != nil {
		t.Fatal(err)
	}
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		t.Fatal("config dir not created")
	}
}
