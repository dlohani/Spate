package download

import (
	"archive/zip"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// extractArchive unpacks a completed download into destDir when it is a
// supported archive. Currently only .zip is supported natively; other formats
// (.rar, .7z) require external tools and return an error.
func extractArchive(archivePath, destDir string) error {
	switch strings.ToLower(filepath.Ext(archivePath)) {
	case ".zip":
		return extractZip(archivePath, destDir)
	case ".rar", ".7z":
		return fmt.Errorf("extract: %s archives are not supported natively", filepath.Ext(archivePath))
	default:
		return fmt.Errorf("extract: %q is not a recognized archive", filepath.Base(archivePath))
	}
}

// extractZip unpacks a zip into destDir, guarding against path traversal
// ("zip slip") by rejecting any entry that would escape destDir.
func extractZip(zipPath, destDir string) error {
	r, err := zip.OpenReader(zipPath)
	if err != nil {
		return err
	}
	defer r.Close()

	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return err
	}
	root, err := filepath.Abs(destDir)
	if err != nil {
		return err
	}

	for _, f := range r.File {
		target := filepath.Join(root, f.Name)
		// Ensure the resolved path stays within destDir.
		if target != root && !strings.HasPrefix(target, root+string(os.PathSeparator)) {
			return fmt.Errorf("extract: entry %q escapes destination", f.Name)
		}
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
			continue
		}
		if err := writeZipFile(f, target); err != nil {
			return err
		}
	}
	return nil
}

func writeZipFile(f *zip.File, target string) error {
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	rc, err := f.Open()
	if err != nil {
		return err
	}
	defer rc.Close()

	out, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, f.Mode()|0o200)
	if err != nil {
		return err
	}
	defer out.Close()
	if _, err := io.Copy(out, rc); err != nil { //nolint:gosec // sizes are user-initiated downloads
		return err
	}
	return nil
}
