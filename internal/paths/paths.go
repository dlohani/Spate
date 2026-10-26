// Package paths locates Spate's per-user config folder and migrates the files
// a previous install wrote under the product's old name, Cascade, so an
// upgrade keeps settings, the browser pairing token, the queue and the UI
// preferences without the user noticing.
package paths

import (
	"errors"
	"os"
	"path/filepath"
)

// Name is the config folder name under the OS user config directory.
const Name = "spate"

// legacyName is the folder the product used before it was renamed.
const legacyName = "cascade"

// migrated are the per-user files worth carrying over; binaries and the
// extension copy an old installer left in the same folder on macOS are not.
var migrated = []string{"settings.json", "token", "queue.json", "ui.json"}

// ConfigDir returns the per-user config folder (created on demand) after
// migrating any legacy files into it.
func ConfigDir() (string, error) {
	base, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return ConfigDirIn(base)
}

// ConfigDirIn is ConfigDir under an explicit base (tests). A legacy file is
// moved only when the new folder lacks a file of that name, so a folder that
// already has new settings is never overwritten by old ones.
func ConfigDirIn(base string) (string, error) {
	dir := filepath.Join(base, Name)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	old := filepath.Join(base, legacyName)
	if _, err := os.Stat(old); err != nil {
		return dir, nil
	}
	for _, f := range migrated {
		dst := filepath.Join(dir, f)
		if _, err := os.Stat(dst); err == nil {
			continue
		}
		src := filepath.Join(old, f)
		if _, err := os.Stat(src); err != nil {
			continue
		}
		if err := os.Rename(src, dst); err != nil && !errors.Is(err, os.ErrNotExist) {
			return dir, err
		}
	}
	return dir, nil
}
