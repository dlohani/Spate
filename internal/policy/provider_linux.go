//go:build linux

package policy

import (
	"fmt"
	"os/exec"
)

func provider() (Conditions, error) {
	return linuxConditions{sysfs: "/sys/class/power_supply", run: func(name string, args ...string) ([]byte, error) {
		return exec.Command(name, args...).Output()
	}}, nil
}

// linuxConditions reads the default route from iproute2, the Wi-Fi devices
// from NetworkManager's nmcli, and battery state from sysfs. Hosts without
// NetworkManager cannot answer OnWiFi and get an error (the CLI then refuses
// -wifi-only with a clear message rather than guessing).
type linuxConditions struct {
	sysfs string
	run   func(name string, args ...string) ([]byte, error)
}

func (c linuxConditions) OnWiFi() (bool, error) {
	route, err := c.run("ip", "route", "show", "default")
	if err != nil {
		return false, fmt.Errorf("ip route: %w", err)
	}
	dev := parseDefaultRouteDev(string(route))
	if dev == "" {
		return false, errNoDefaultRoute
	}
	devs, err := c.run("nmcli", "-t", "-f", "DEVICE,TYPE", "device")
	if err != nil {
		return false, fmt.Errorf("nmcli (NetworkManager) unavailable: %w", err)
	}
	return parseWifiDevices(string(devs))[dev], nil
}

func (c linuxConditions) Battery() (int, bool, error) { return readBattery(c.sysfs) }
