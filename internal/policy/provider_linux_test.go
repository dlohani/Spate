//go:build linux

package policy

import (
	"errors"
	"testing"
)

func TestLinuxOnWiFi(t *testing.T) {
	fake := func(route, devs string) linuxConditions {
		return linuxConditions{run: func(name string, args ...string) ([]byte, error) {
			switch name {
			case "ip":
				return []byte(route), nil
			case "nmcli":
				if devs == "" {
					return nil, errors.New("not found")
				}
				return []byte(devs), nil
			}
			return nil, errors.New("unexpected " + name)
		}}
	}
	if on, err := fake("default via 1.1.1.1 dev wlan0\n", "wlan0:wifi\neth0:ethernet\n").OnWiFi(); err != nil || !on {
		t.Fatalf("wifi route: %v %v", on, err)
	}
	if on, err := fake("default via 1.1.1.1 dev eth0\n", "wlan0:wifi\neth0:ethernet\n").OnWiFi(); err != nil || on {
		t.Fatalf("ethernet route: %v %v", on, err)
	}
	if _, err := fake("", "wlan0:wifi\n").OnWiFi(); !errors.Is(err, errNoDefaultRoute) {
		t.Fatalf("offline: %v", err)
	}
	if _, err := fake("default via 1.1.1.1 dev wlan0\n", "").OnWiFi(); err == nil {
		t.Fatal("missing nmcli should error")
	}
}
