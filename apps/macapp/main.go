// Command cascade-mac is a minimal native macOS GUI over the cascade engine,
// built with Fyne (pure Go, no full Xcode required). It drives the same
// internal/job manager the CLI uses, so it exercises the real download core.
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
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/dialog"
	"fyne.io/fyne/v2/driver/desktop"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"

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
	captureURL := ""
	if addr, err := capSrv.Start(); err == nil {
		captureURL = "http://" + addr
	}
	defer capSrv.Close()

	a := app.New()
	w := a.NewWindow("Cascade")
	w.Resize(fyne.NewSize(720, 480))

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

	// Stay resident: closing the window hides it, so the capture endpoint and
	// any running downloads keep going. The app lives in the menu bar; use
	// "Quit" there to actually exit.
	w.SetCloseIntercept(func() { w.Hide() })
	if desk, ok := a.(desktop.App); ok {
		desk.SetSystemTrayMenu(fyne.NewMenu("Cascade",
			fyne.NewMenuItem("Open Cascade", func() { w.Show(); w.RequestFocus() }),
			fyne.NewMenuItemSeparator(),
			fyne.NewMenuItem("Quit", func() { a.Quit() }),
		))
		desk.SetSystemTrayIcon(theme.DownloadIcon())
	}

	urlEntry := widget.NewEntry()
	urlEntry.SetPlaceHolder("https://example.com/file.bin")

	destEntry := widget.NewEntry()
	destEntry.SetText(defaultDownloadDir())

	connEntry := widget.NewEntry()
	connEntry.SetText("8")

	status := widget.NewLabel("")

	rows := container.NewVBox()
	scroll := container.NewVScroll(rows)

	add := func() {
		u := urlEntry.Text
		if u == "" {
			status.SetText("enter a URL")
			return
		}
		if _, err := url.ParseRequestURI(u); err != nil {
			status.SetText("invalid URL: " + err.Error())
			return
		}
		conns, _ := strconv.Atoi(connEntry.Text)
		out := filepath.Join(destEntry.Text, filenameFor(u))
		if _, err := mgr.Add(job.Spec{URL: u, Out: out, Options: download.Options{Conns: conns}}); err != nil {
			status.SetText("add failed: " + err.Error())
			return
		}
		status.SetText("queued " + out)
		urlEntry.SetText("")
	}

	addBtn := widget.NewButton("Download", add)
	urlEntry.OnSubmitted = func(string) { add() }

	// Browser-capture info: the token is shown in a read-only-style entry so it
	// can be copied into the browser extension's options.
	tokenField := widget.NewEntry()
	tokenField.SetText(token)
	captureLabel := widget.NewLabel("Browser capture: " + orDisabled(captureURL))
	extLabel := widget.NewLabel("Extension: not connected (load it in chrome://extensions, then Pair)")
	extStatus := func() string {
		last := capSrv.LastExtensionContact()
		if last.IsZero() {
			return "Extension: not connected (load it in chrome://extensions, then Pair)"
		}
		return fmt.Sprintf("Extension: connected (last contact %ds ago)", int(time.Since(last).Seconds()))
	}

	form := container.NewVBox(
		widget.NewLabel("URL"),
		urlEntry,
		container.NewGridWithColumns(2,
			container.NewVBox(widget.NewLabel("Save to"), destEntry),
			container.NewVBox(widget.NewLabel("Connections"), connEntry),
		),
		addBtn,
		widget.NewSeparator(),
		captureLabel,
		extLabel,
		container.NewVBox(widget.NewLabel("Extension token (only needed for manual setup; use Pair instead)"), tokenField),
		widget.NewSeparator(),
		container.NewBorder(nil, nil, widget.NewLabel("Downloads"), container.NewHBox(
			widget.NewButton("Cancel all", func() { mgr.CancelAll() }),
			widget.NewButton("Clear finished", func() { mgr.ClearFinished() }),
		)),
	)
	w.SetContent(container.NewBorder(form, status, nil, nil, scroll))

	// Refresh the job list on a timer, on the UI thread.
	go func() {
		t := time.NewTicker(500 * time.Millisecond)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				snap := mgr.Statuses()
				ext := extStatus()
				fyne.Do(func() {
					extLabel.SetText(ext)
					rows.Objects = nil
					for _, s := range snap {
						rows.Add(makeRow(mgr, s))
					}
					rows.Refresh()
				})
			}
		}
	}()

	w.ShowAndRun()
}

func makeRow(mgr *job.Manager, s job.Status) fyne.CanvasObject {
	pct := 0.0
	if s.Total > 0 {
		pct = float64(s.Bytes) / float64(s.Total)
	}
	title := fmt.Sprintf("%s  [%s]  %s / %s", s.ID, s.State,
		humanBytes(s.Bytes), humanBytes(s.Total))
	if s.Err != nil {
		title += "  " + s.Err.Error()
	}
	name := widget.NewLabel(title)

	bar := widget.NewProgressBar()
	bar.SetValue(pct)

	id := s.ID
	var primary *widget.Button
	switch s.State {
	case job.Running, job.Pending:
		primary = widget.NewButton("Pause", func() { _ = mgr.Pause(id) })
	case job.Paused:
		primary = widget.NewButton("Resume", func() { _ = mgr.Resume(id) })
	default:
		primary = widget.NewButton(stateLabel(s.State), nil)
		primary.Disable()
	}

	var secondary *widget.Button
	if s.State.Terminal() {
		secondary = widget.NewButton("Remove", func() { _ = mgr.Remove(id) })
	} else {
		secondary = widget.NewButton("Cancel", func() { _ = mgr.Cancel(id) })
	}

	buttons := container.NewHBox(primary, secondary)
	return container.NewVBox(container.NewBorder(nil, nil, nil, buttons, name), bar)
}

// stateLabel returns a short label for a terminal state's disabled primary button.
func stateLabel(s job.State) string {
	switch s {
	case job.Done:
		return "Done"
	case job.Failed:
		return "Failed"
	case job.Cancelled:
		return "Cancelled"
	default:
		return "-"
	}
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
// otherwise one persisted under the user config dir (generated once). A stable
// token means the browser extension is configured only once, not per restart.
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

func orDisabled(url string) string {
	if url == "" {
		return "disabled (port in use)"
	}
	return "ON at " + url
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

func humanBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for x := n / unit; x >= unit; x /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTPE"[exp])
}
