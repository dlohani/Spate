// Command cascade-mac is the native macOS app over the cascade engine, built
// with Fyne (pure Go, no full Xcode required). It drives the same internal/job
// manager the CLI uses; the UI lives in the ui package (design system + views).
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/driver/desktop"
	"fyne.io/fyne/v2/theme"

	"cascade/apps/macapp/ui"
	"cascade/internal/download"
	"cascade/internal/job"
	"cascade/internal/localapi"
)

func main() {
	// Single instance: if a Cascade endpoint is already answering, this launch
	// (e.g. a second click, or the native host racing) should not start another.
	if alreadyRunning() {
		fmt.Fprintln(os.Stderr, "cascade: already running")
		return
	}

	mgr := job.New(3)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = mgr.Serve(ctx) }()

	// Browser capture endpoint (the extension posts downloads here).
	token := loadOrCreateToken()
	capSrv := localapi.New(mgr, token, defaultDownloadDir())
	_, _ = capSrv.Start()
	defer capSrv.Close()

	a := app.New()
	a.Settings().SetTheme(ui.Theme{})
	a.SetIcon(fyne.NewStaticResource("cascade.png", appIconPNG))
	w := a.NewWindow("Cascade")
	w.Resize(fyne.NewSize(760, 540))

	// One-click pairing: when the browser extension asks to connect, show an
	// Allow/Deny prompt and release the token only on Allow.
	capSrv.PairFunc = func() bool {
		decided := make(chan bool, 1)
		fyne.Do(func() {
			w.Show()
			w.RequestFocus()
			dialog.ShowConfirm("Browser extension",
				"A browser extension wants to connect to Cascade to hand off downloads.\nAllow?",
				func(ok bool) { decided <- ok }, w)
		})
		select {
		case ok := <-decided:
			return ok
		case <-time.After(90 * time.Second):
			return false
		}
	}

	// Resume any downloads orphaned by a previous run (their .cascade sidecars
	// remain next to the partial file).
	resumeOrphans(mgr, defaultDownloadDir())

	// Stay resident: closing the window hides it; the app lives in the menu bar.
	w.SetCloseIntercept(func() { w.Hide() })
	if desk, ok := a.(desktop.App); ok {
		desk.SetSystemTrayMenu(fyne.NewMenu("Cascade",
			fyne.NewMenuItem("Open Cascade", func() { w.Show(); w.RequestFocus() }),
			fyne.NewMenuItemSeparator(),
			fyne.NewMenuItem("Quit", func() { a.Quit() }),
		))
		desk.SetSystemTrayIcon(theme.DownloadIcon())
	}

	view := ui.Build(&controller{mgr: mgr}, defaultDownloadDir(), func() fyne.ThemeVariant {
		return a.Settings().ThemeVariant()
	})
	w.SetContent(view.Root)

	// Refresh the list on a timer, on the UI thread (rows update in place).
	go func() {
		t := time.NewTicker(500 * time.Millisecond)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				fyne.Do(view.Refresh)
			}
		}
	}()

	// --background (autostart): run with only the tray icon; the window opens
	// from the tray menu or when a download arrives.
	for _, arg := range os.Args[1:] {
		if arg == "--background" {
			a.Run()
			return
		}
	}
	w.ShowAndRun()
}

// controller adapts the job manager to what the UI needs.
type controller struct{ mgr *job.Manager }

func (c *controller) Statuses() []job.Status     { return c.mgr.Statuses() }
func (c *controller) Pause(id string) error      { return c.mgr.Pause(id) }
func (c *controller) Resume(id string) error     { return c.mgr.Resume(id) }
func (c *controller) Cancel(id string) error     { return c.mgr.Cancel(id) }
func (c *controller) Remove(id string) error     { return c.mgr.Remove(id) }
func (c *controller) ClearFinished() int         { return c.mgr.ClearFinished() }
func (c *controller) CancelAll()                 { c.mgr.CancelAll() }
func (c *controller) Reveal(p string) {
	switch runtime.GOOS {
	case "darwin":
		_ = exec.Command("open", "-R", p).Start()
	case "windows":
		_ = exec.Command("explorer", "/select,", p).Start()
	default:
		_ = exec.Command("xdg-open", filepath.Dir(p)).Start()
	}
}
func (c *controller) Add(rawURL, dir string, conns int) error {
	if _, err := url.ParseRequestURI(rawURL); err != nil {
		return fmt.Errorf("invalid URL")
	}
	if dir == "" {
		dir = defaultDownloadDir()
	}
	out := filepath.Join(dir, filenameFor(rawURL))
	_, err := c.mgr.Add(job.Spec{URL: rawURL, Out: out, Options: download.Options{Conns: conns, Resume: true}})
	return err
}

// alreadyRunning reports whether a Cascade endpoint is already up on the ports
// the extension probes.
func alreadyRunning() bool {
	c := &http.Client{Timeout: 300 * time.Millisecond}
	for _, p := range []int{localapi.DefaultPort, localapi.DefaultPort + 1, localapi.DefaultPort + 2} {
		resp, err := c.Get(fmt.Sprintf("http://127.0.0.1:%d/ping", p))
		if err != nil {
			continue
		}
		var body struct {
			App string `json:"app"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&body)
		resp.Body.Close()
		if body.App == "cascade" {
			return true
		}
	}
	return false
}

// resumeOrphans re-queues downloads whose .cascade sidecar is still present in
// dir (left by a crash, quit, or restart), continuing from where they stopped.
func resumeOrphans(mgr *job.Manager, dir string) {
	sidecars, _ := filepath.Glob(filepath.Join(dir, "*.cascade"))
	for _, sc := range sidecars {
		out := strings.TrimSuffix(sc, ".cascade")
		ctrl, err := download.LoadControl(out)
		if err != nil || ctrl == nil || ctrl.URL == "" {
			continue
		}
		if _, err := os.Stat(out); err != nil {
			continue // partial file gone; nothing to resume
		}
		_, _ = mgr.Add(job.Spec{URL: ctrl.URL, Out: out, Options: download.Options{Resume: true}})
	}
}

func randToken() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "cascade-token"
	}
	return hex.EncodeToString(b)
}

// loadOrCreateToken returns a stable capture token: the CASCADE_TOKEN env if set,
// otherwise one persisted under the user config dir (generated once).
func loadOrCreateToken() string {
	if t := os.Getenv("CASCADE_TOKEN"); t != "" {
		return t
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		return randToken()
	}
	cdir := filepath.Join(dir, "cascade")
	tokenPath := filepath.Join(cdir, "token")
	if b, err := os.ReadFile(tokenPath); err == nil {
		if t := strings.TrimSpace(string(b)); t != "" {
			return t
		}
	}
	t := randToken()
	if err := os.MkdirAll(cdir, 0o700); err == nil {
		_ = os.WriteFile(tokenPath, []byte(t), 0o600)
	}
	return t
}

func defaultDownloadDir() string {
	if home, err := os.UserHomeDir(); err == nil {
		d := filepath.Join(home, "Downloads")
		if fi, err := os.Stat(d); err == nil && fi.IsDir() {
			return d
		}
		return home
	}
	return "."
}

func filenameFor(rawURL string) string {
	if u, err := url.Parse(rawURL); err == nil {
		if base := path.Base(u.Path); base != "" && base != "/" && base != "." {
			return base
		}
	}
	return "download.bin"
}
