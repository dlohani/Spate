//go:build darwin

package policy

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

func provider() (Conditions, error) { return darwinConditions{}, nil }

type darwinConditions struct{}

// OnWiFi finds the interface backing the default route and checks whether it is
// a Wi-Fi hardware port.
func (darwinConditions) OnWiFi() (bool, error) {
	iface, err := defaultRouteInterface()
	if err != nil {
		return false, err
	}
	wifiIface, err := wifiInterface()
	if err != nil {
		return false, err
	}
	return iface != "" && iface == wifiIface, nil
}

// Battery parses `pmset -g batt` for charge percentage and power source.
func (darwinConditions) Battery() (int, bool, error) {
	out, err := exec.Command("pmset", "-g", "batt").Output()
	if err != nil {
		return 0, false, err
	}
	text := string(out)
	onAC := strings.Contains(text, "AC Power")
	pct := -1
	if i := strings.IndexByte(text, '%'); i > 0 {
		start := i - 1
		for start > 0 && text[start-1] >= '0' && text[start-1] <= '9' {
			start--
		}
		if n, e := strconv.Atoi(text[start:i]); e == nil {
			pct = n
		}
	}
	if pct < 0 {
		return 0, onAC, fmt.Errorf("could not parse battery percentage from pmset")
	}
	return pct, onAC, nil
}

func defaultRouteInterface() (string, error) {
	out, err := exec.Command("route", "-n", "get", "default").Output()
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "interface:") {
			return strings.TrimSpace(strings.TrimPrefix(line, "interface:")), nil
		}
	}
	return "", fmt.Errorf("no default route interface found")
}

// wifiInterface returns the device name of the Wi-Fi hardware port (e.g. en0).
func wifiInterface() (string, error) {
	out, err := exec.Command("networksetup", "-listallhardwareports").Output()
	if err != nil {
		return "", err
	}
	lines := strings.Split(string(out), "\n")
	for i, line := range lines {
		if strings.Contains(line, "Wi-Fi") || strings.Contains(line, "AirPort") {
			for j := i + 1; j < len(lines) && j < i+4; j++ {
				if strings.HasPrefix(lines[j], "Device:") {
					return strings.TrimSpace(strings.TrimPrefix(lines[j], "Device:")), nil
				}
			}
		}
	}
	return "", fmt.Errorf("no Wi-Fi hardware port found")
}
