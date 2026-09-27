// Package policy builds download gates from platform conditions: only on Wi-Fi,
// or only when battery is above a threshold (or on AC power).
//
// Detection is inherently OS-specific and best-effort. A full implementation is
// provided for macOS (darwin) by shelling out to system tools; other platforms
// return an unsupported error so callers can decide how to proceed.
package policy

import (
	"fmt"

	"cascade/internal/download"
)

// Options selects which conditions to enforce.
type Options struct {
	WiFiOnly   bool // only allow downloads while on a Wi-Fi network
	BatteryMin int  // require battery >= this percent (0 disables); AC power passes
}

// Conditions is the platform-specific source of truth. Providers implement it.
type Conditions interface {
	OnWiFi() (bool, error)          // active default route is a Wi-Fi interface
	Battery() (percent int, onAC bool, err error)
}

// Gate builds a download.GateFunc from opts using the platform provider. It
// returns an error if a requested condition can't be evaluated on this OS.
func Gate(opts Options) (download.GateFunc, error) {
	if !opts.WiFiOnly && opts.BatteryMin <= 0 {
		return nil, nil // nothing to enforce
	}
	c, err := provider()
	if err != nil {
		return nil, err
	}
	// Probe once up front so an unsupported platform fails fast with a clear error.
	if opts.WiFiOnly {
		if _, err := c.OnWiFi(); err != nil {
			return nil, fmt.Errorf("wifi-only policy unavailable: %w", err)
		}
	}
	if opts.BatteryMin > 0 {
		if _, _, err := c.Battery(); err != nil {
			return nil, fmt.Errorf("battery policy unavailable: %w", err)
		}
	}

	return func() (bool, string) {
		if opts.WiFiOnly {
			onWiFi, err := c.OnWiFi()
			if err != nil {
				return false, fmt.Sprintf("cannot determine network type: %v", err)
			}
			if !onWiFi {
				return false, "waiting for Wi-Fi"
			}
		}
		if opts.BatteryMin > 0 {
			pct, onAC, err := c.Battery()
			if err != nil {
				return false, fmt.Sprintf("cannot determine battery: %v", err)
			}
			if !onAC && pct < opts.BatteryMin {
				return false, fmt.Sprintf("battery %d%% below %d%% and not on AC", pct, opts.BatteryMin)
			}
		}
		return true, ""
	}, nil
}
