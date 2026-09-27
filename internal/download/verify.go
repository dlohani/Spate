package download

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"strings"
)

// verifySHA256 reads path and checks its SHA-256 against expectedHex
// (case-insensitive). An empty expectedHex skips the check.
func verifySHA256(path, expectedHex string) error {
	expectedHex = strings.TrimSpace(strings.ToLower(expectedHex))
	if expectedHex == "" {
		return nil
	}
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return err
	}
	got := hex.EncodeToString(h.Sum(nil))
	if got != expectedHex {
		return fmt.Errorf("sha256 mismatch: got %s, want %s", got, expectedHex)
	}
	return nil
}
