// Command cascade-host is the browser native-messaging host for Cascade.
//
// The browser launches this process itself when the extension calls
// chrome.runtime.sendNativeMessage("com.cascade.host", ...). It makes sure the
// resident Cascade app is running (launching it, detached, if not), waits for
// its loopback endpoint, and replies with the endpoint address and the capture
// token. Native messaging is a browser-enforced trusted channel (only the
// extension IDs listed in the host manifest can invoke it), so handing over the
// token here is safe and makes pairing automatic.
//
// Protocol (both directions): 4-byte little-endian length, then a JSON object.
package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const (
	appBundle    = "Cascade.app" // macOS: Flutter app bundle installed next to this host (preferred)
	bundleDir    = "cascade_app" // Linux/Windows: Flutter bundle directory installed next to this host
	bundleBinary = "cascade_app" // executable inside the bundle directory (+ .exe on Windows)
	guiBinary    = "cascade-gui" // Fyne fallback GUI binary (+ .exe on Windows)
	legacyBinary = "cascade-mac" // older name of the Fyne binary on macOS installs
	launchWait   = 20 * time.Second
	ports        = "8760,8761,8762"
)

type request struct {
	Type string `json:"type"`
}

type reply struct {
	OK       bool   `json:"ok"`
	Addr     string `json:"addr,omitempty"`
	Token    string `json:"token,omitempty"`
	Launched bool   `json:"launched"`
	Error    string `json:"error,omitempty"`
}

func main() {
	var req request
	if err := readMessage(os.Stdin, &req); err != nil {
		writeMessage(os.Stdout, reply{Error: "bad request: " + err.Error()})
		return
	}
	writeMessage(os.Stdout, ensure())
}

// ensure returns the app's endpoint (launching the app if needed) and token.
func ensure() reply {
	r := reply{}
	if addr := findApp(); addr != "" {
		r.OK, r.Addr = true, addr
	} else {
		if err := launchApp(); err != nil {
			r.Error = "launch failed: " + err.Error()
			return r
		}
		r.Launched = true
		deadline := time.Now().Add(launchWait)
		for time.Now().Before(deadline) {
			if addr := findApp(); addr != "" {
				r.OK, r.Addr = true, addr
				break
			}
			time.Sleep(200 * time.Millisecond)
		}
		if !r.OK {
			r.Error = "app did not come up within " + launchWait.String()
			return r
		}
	}
	r.Token = readToken()
	return r
}

// macAppBundle returns the installed Cascade.app on macOS: the per-user or
// system Applications folder (where the installers put it), else the legacy
// location next to this host. "" when none exists.
func macAppBundle(hostDir string) string {
	home, _ := os.UserHomeDir()
	for _, p := range []string{
		filepath.Join(home, "Applications", appBundle),
		filepath.Join("/Applications", appBundle),
		filepath.Join(hostDir, appBundle),
	} {
		if dirExists(p) {
			return p
		}
	}
	return ""
}

// findApp returns the address of a running Cascade endpoint, or "".
func findApp() string {
	c := &http.Client{Timeout: 400 * time.Millisecond}
	for _, p := range strings.Split(ports, ",") {
		addr := "127.0.0.1:" + p
		resp, err := c.Get("http://" + addr + "/ping")
		if err != nil {
			continue
		}
		var body struct {
			App string `json:"app"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&body)
		resp.Body.Close()
		if body.App == "cascade" {
			return addr
		}
	}
	return ""
}

// launchApp starts the resident app detached from this (short-lived) host, and
// serializes concurrent launches with a lock file so two downloads arriving at
// once don't start two apps.
func launchApp() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	dir := filepath.Dir(exe)
	ext := ""
	if runtime.GOOS == "windows" {
		ext = ".exe"
	}
	// Prefer the Flutter app; fall back to the Fyne GUI binary. On macOS the
	// bundle is launched through LaunchServices so it gets a proper GUI session;
	// elsewhere the executable is started detached from this host.
	var cmd *exec.Cmd
	switch {
	case runtime.GOOS == "darwin" && macAppBundle(dir) != "":
		cmd = exec.Command("open", "-a", macAppBundle(dir))
	case fileExists(filepath.Join(dir, bundleDir, bundleBinary+ext)):
		cmd = exec.Command(filepath.Join(dir, bundleDir, bundleBinary+ext))
		detach(cmd)
	case fileExists(filepath.Join(dir, guiBinary+ext)):
		cmd = exec.Command(filepath.Join(dir, guiBinary+ext))
		detach(cmd)
	case fileExists(filepath.Join(dir, legacyBinary)):
		cmd = exec.Command(filepath.Join(dir, legacyBinary))
		detach(cmd)
	default:
		return fmt.Errorf("no Cascade app found next to %s", exe)
	}

	// Serialize concurrent launches (two downloads arriving at once).
	cfg, _ := os.UserConfigDir()
	lockPath := filepath.Join(cfg, "cascade", "launch.lock")
	_ = os.MkdirAll(filepath.Dir(lockPath), 0o700)
	unlock, ok := tryLock(lockPath)
	if !ok {
		return nil // another host is launching it; the caller polls /ping
	}
	defer unlock()
	if findApp() != "" {
		return nil // came up while we waited for the lock
	}

	cmd.Stdin, cmd.Stdout, cmd.Stderr = nil, nil, nil
	if err := cmd.Start(); err != nil {
		return err
	}
	return cmd.Process.Release()
}

func dirExists(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

func fileExists(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && !fi.IsDir()
}

// readToken returns the persisted capture token the app uses ("" if none yet;
// the app creates it on first start).
func readToken() string {
	cfg, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	b, err := os.ReadFile(filepath.Join(cfg, "cascade", "token"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

func readMessage(r io.Reader, v any) error {
	var n uint32
	if err := binary.Read(r, binary.LittleEndian, &n); err != nil {
		return err
	}
	if n > 1<<20 {
		return errors.New("message too large")
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return err
	}
	return json.Unmarshal(buf, v)
}

func writeMessage(w io.Writer, v any) {
	b, _ := json.Marshal(v)
	_ = binary.Write(w, binary.LittleEndian, uint32(len(b)))
	_, _ = w.Write(b)
}
