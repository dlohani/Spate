package policy

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseDefaultRouteDev(t *testing.T) {
	cases := map[string]string{
		"default via 192.168.1.1 dev wlan0 proto dhcp src 192.168.1.23 metric 600\n":                           "wlan0",
		"default via 10.0.0.1 dev enp3s0 proto static metric 100\ndefault via 10.0.0.2 dev wlan0 metric 600\n": "enp3s0",
		"":                      "",
		"unreachable default\n": "",
	}
	for in, want := range cases {
		if got := parseDefaultRouteDev(in); got != want {
			t.Errorf("%q: got %q want %q", in, got, want)
		}
	}
}

func TestParseWifiDevices(t *testing.T) {
	out := "wlan0:wifi\nenp3s0:ethernet\nlo:loopback\np2p-dev-wlan0:wifi-p2p\n\n"
	got := parseWifiDevices(out)
	if !got["wlan0"] || got["enp3s0"] || got["p2p-dev-wlan0"] || len(got) != 1 {
		t.Fatalf("wifi devices = %v", got)
	}
}

func writeSys(t *testing.T, root string, rel, val string) {
	t.Helper()
	p := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(val+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestReadBattery(t *testing.T) {
	root := t.TempDir()
	writeSys(t, root, "BAT0/type", "Battery")
	writeSys(t, root, "BAT0/capacity", "42")
	writeSys(t, root, "AC/type", "Mains")
	writeSys(t, root, "AC/online", "0")
	pct, ac, err := readBattery(root)
	if err != nil || pct != 42 || ac {
		t.Fatalf("got %d %v %v, want 42 false nil", pct, ac, err)
	}
	writeSys(t, root, "AC/online", "1")
	if _, ac, _ := readBattery(root); !ac {
		t.Fatal("AC online=1 not detected")
	}

	desktop := t.TempDir()
	writeSys(t, desktop, "AC/type", "Mains")
	writeSys(t, desktop, "AC/online", "1")
	pct, ac, err = readBattery(desktop)
	if err != nil || pct != 100 || !ac {
		t.Fatalf("desktop: got %d %v %v, want 100 true nil", pct, ac, err)
	}

	if _, _, err := readBattery(filepath.Join(root, "missing")); err == nil {
		t.Fatal("missing sysfs should error")
	}
}
