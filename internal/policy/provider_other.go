//go:build !darwin && !linux

package policy

import (
	"fmt"
	"runtime"
)

// provider reports that platform conditions are unsupported on this OS. Wi-Fi and
// battery detection are implemented for macOS and Linux so far.
func provider() (Conditions, error) {
	return nil, fmt.Errorf("wifi-only/battery policies are not implemented on %s", runtime.GOOS)
}
