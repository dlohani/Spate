// Command cascade-mac is a minimal native macOS GUI over the cascade engine,
// built with Fyne (pure Go, no full Xcode required). It drives the same
// internal/job manager the CLI uses, so it exercises the real download core.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"

	"cascade/internal/download"
	"cascade/internal/job"
	"cascade/internal/localapi"
)

func main() {
	mgr := job.New(3)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = mgr.Serve(ctx) }()

	// Browser capture endpoint (the extension posts downloads here).
	token := os.Getenv("CASCADE_TOKEN")
	if token == "" {
		token = randToken()
	}
	capSrv := localapi.New(mgr, token, defaultDownloadDir())
	captureURL := ""
	if addr, err := capSrv.Start(); err == nil {
		captureURL = "http://" + addr
	}
	defer capSrv.Close()

	a := app.New()
	w := a.NewWindow("Cascade")
	w.Resize(fyne.NewSize(720, 480))

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
		container.NewVBox(widget.NewLabel("Extension token (paste into the browser extension)"), tokenField),
		widget.NewSeparator(),
		widget.NewLabel("Downloads"),
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
				fyne.Do(func() {
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

	var btn *widget.Button
	switch s.State {
	case job.Running, job.Pending:
		id := s.ID
		btn = widget.NewButton("Pause", func() { _ = mgr.Pause(id) })
	case job.Paused:
		id := s.ID
		btn = widget.NewButton("Resume", func() { _ = mgr.Resume(id) })
	default:
		btn = widget.NewButton("Done", nil)
		btn.Disable()
	}

	return container.NewVBox(container.NewBorder(nil, nil, nil, btn, name), bar)
}

func randToken() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "cascade-token"
	}
	return hex.EncodeToString(b)
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
