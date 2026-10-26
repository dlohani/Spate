package policy

// Parsers for the Linux provider's inputs. They have no build tag so their
// tests run on every development host; the provider that shells out lives in
// provider_linux.go.

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// parseDefaultRouteDev returns the interface after "dev" in the first line
// of `ip route show default`, or "" when there is none.
func parseDefaultRouteDev(out string) string {
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		for i := 0; i+1 < len(f); i++ {
			if f[i] == "dev" {
				return f[i+1]
			}
		}
	}
	return ""
}

// parseWifiDevices returns the devices whose TYPE is wifi in the terse
// output of `nmcli -t -f DEVICE,TYPE device` ("wlan0:wifi").
func parseWifiDevices(out string) map[string]bool {
	wifi := map[string]bool{}
	for _, line := range strings.Split(out, "\n") {
		dev, typ, ok := strings.Cut(strings.TrimSpace(line), ":")
		if ok && typ == "wifi" && dev != "" {
			wifi[dev] = true
		}
	}
	return wifi
}

// readBattery reads the kernel's power-supply class under sysfs: the first
// BAT*/capacity for the percentage and any supply of type Mains with
// online=1 for AC. A machine without a battery (a desktop) reports 100 and
// on AC, so a battery policy never blocks it.
func readBattery(sysfs string) (percent int, onAC bool, err error) {
	entries, err := os.ReadDir(sysfs)
	if err != nil {
		return 0, false, err
	}
	percent = -1
	for _, e := range entries {
		dir := filepath.Join(sysfs, e.Name())
		typ := strings.TrimSpace(readStr(filepath.Join(dir, "type")))
		switch {
		case typ == "Mains" || strings.HasPrefix(e.Name(), "AC"):
			if strings.TrimSpace(readStr(filepath.Join(dir, "online"))) == "1" {
				onAC = true
			}
		case typ == "Battery" || strings.HasPrefix(e.Name(), "BAT"):
			if percent >= 0 {
				continue
			}
			n, err := strconv.Atoi(strings.TrimSpace(readStr(filepath.Join(dir, "capacity"))))
			if err == nil {
				percent = n
			}
		}
	}
	if percent < 0 {
		return 100, true, nil // no battery: a desktop or a VM
	}
	if percent > 100 {
		return 0, onAC, fmt.Errorf("battery capacity %d out of range", percent)
	}
	return percent, onAC, nil
}

func readStr(p string) string {
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	return string(b)
}

// errNoDefaultRoute is returned when the machine has no default route (offline).
var errNoDefaultRoute = errors.New("no default route")
