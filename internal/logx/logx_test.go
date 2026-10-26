package logx

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestToFileAppendsWithMode(t *testing.T) {
	path := filepath.Join(t.TempDir(), "spate.log")
	lg, err := ToFile(path, 5<<20)
	if err != nil {
		t.Fatal(err)
	}
	lg.Info("hello", "k", 1)
	lg2, err := ToFile(path, 5<<20)
	if err != nil {
		t.Fatal(err)
	}
	lg2.Info("again")
	b, _ := os.ReadFile(path)
	if !strings.Contains(string(b), "msg=hello k=1") || !strings.Contains(string(b), "msg=again") {
		t.Fatalf("log content: %q", b)
	}
	fi, _ := os.Stat(path)
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode %o", fi.Mode().Perm())
	}
}

func TestToFileRotatesWhenLarge(t *testing.T) {
	path := filepath.Join(t.TempDir(), "spate.log")
	big := make([]byte, 6<<20)
	if err := os.WriteFile(path, big, 0o600); err != nil {
		t.Fatal(err)
	}
	lg, err := ToFile(path, 5<<20)
	if err != nil {
		t.Fatal(err)
	}
	lg.Info("fresh")
	fi, _ := os.Stat(path)
	if fi.Size() > 1024 {
		t.Fatalf("current log not rotated: %d bytes", fi.Size())
	}
	old, err := os.Stat(path + ".1")
	if err != nil || old.Size() != int64(len(big)) {
		t.Fatalf("rotated file: %v size %v", err, old)
	}
}
