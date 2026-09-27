package ui

import (
	"fmt"
	"image/color"
	"net/url"
	"path/filepath"
	"sort"
	"time"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/canvas"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/layout"
	"fyne.io/fyne/v2/theme"
	"fyne.io/fyne/v2/widget"

	"cascade/internal/job"
)

// Controller is what the UI needs from the app: the queue and its actions.
type Controller interface {
	Statuses() []job.Status
	Add(rawURL, dir string, conns int) error
	Pause(id string) error
	Resume(id string) error
	Cancel(id string) error
	Remove(id string) error
	ClearFinished() int
	CancelAll()
	Reveal(path string) // show a finished file (e.g. in Finder)
}

// View is the built window content plus a Refresh to call on a timer.
type View struct {
	Root    fyne.CanvasObject
	Refresh func()

	rows      map[string]*row
	list      *fyne.Container
	empty     fyne.CanvasObject
	count     *widget.Label
	ctl       Controller
	variantFn func() fyne.ThemeVariant
}

// Build assembles the UI. defaultDir is the initial save folder.
func Build(ctl Controller, defaultDir string, variant func() fyne.ThemeVariant) *View {
	v := &View{rows: map[string]*row{}, ctl: ctl, variantFn: variant}

	// Header
	title := widget.NewLabelWithStyle("Cascade", fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	title.SizeName = theme.SizeNameHeadingText
	v.count = widget.NewLabel("")
	v.count.SizeName = theme.SizeNameCaptionText
	v.count.Importance = widget.LowImportance
	header := container.NewHBox(title, layout.NewSpacer(), v.count)

	// Add card
	urlEntry := widget.NewEntry()
	urlEntry.SetPlaceHolder("Paste a link to download")
	dirEntry := widget.NewEntry()
	dirEntry.SetText(defaultDir)
	connEntry := widget.NewEntry()
	connEntry.SetText("8")
	status := widget.NewLabel("")
	status.SizeName = theme.SizeNameCaptionText
	status.Importance = widget.LowImportance

	add := func() {
		u := urlEntry.Text
		if u == "" {
			return
		}
		conns := 8
		fmt.Sscanf(connEntry.Text, "%d", &conns)
		if err := ctl.Add(u, dirEntry.Text, conns); err != nil {
			status.SetText(err.Error())
			status.Show()
			return
		}
		status.SetText("")
		status.Hide()
		urlEntry.SetText("")
	}
	status.Hide() // only shown when there is something to say
	addBtn := widget.NewButtonWithIcon("Download", theme.DownloadIcon(), add)
	addBtn.Importance = widget.HighImportance
	urlEntry.OnSubmitted = func(string) { add() }

	saveTo := widget.NewLabel("Save to")
	saveTo.SizeName = theme.SizeNameCaptionText
	saveTo.Importance = widget.LowImportance
	connsLbl := widget.NewLabel("Connections")
	connsLbl.SizeName = theme.SizeNameCaptionText
	connsLbl.Importance = widget.LowImportance

	addCard := v.card(container.NewVBox(
		container.NewBorder(nil, nil, nil, addBtn, urlEntry),
		container.NewGridWithColumns(2,
			container.NewVBox(saveTo, dirEntry),
			container.NewVBox(connsLbl, connEntry),
		),
		status,
	))

	// Downloads section
	section := widget.NewLabelWithStyle("Downloads", fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	section.SizeName = theme.SizeNameSubHeadingText
	clearBtn := widget.NewButtonWithIcon("Clear finished", theme.ContentClearIcon(), func() { ctl.ClearFinished(); v.Refresh() })
	clearBtn.Importance = widget.LowImportance
	cancelAll := widget.NewButtonWithIcon("Cancel all", theme.CancelIcon(), func() { ctl.CancelAll(); v.Refresh() })
	cancelAll.Importance = widget.LowImportance
	toolbar := container.NewHBox(section, layout.NewSpacer(), cancelAll, clearBtn)

	v.list = container.NewVBox()
	emptyLbl := widget.NewLabel("No downloads yet.\nDownloads you start in the browser appear here.")
	emptyLbl.Alignment = fyne.TextAlignCenter
	emptyLbl.Importance = widget.LowImportance
	v.empty = container.NewCenter(emptyLbl)

	body := container.NewVBox(header, addCard, toolbar, v.list, v.empty)
	v.Root = container.NewVScroll(container.NewPadded(body))
	v.Refresh = v.refresh
	v.refresh()
	return v
}

// card wraps content in a rounded surface with a hairline border.
func (v *View) card(content fyne.CanvasObject) fyne.CanvasObject {
	p := pal(v.variantFn())
	bg := canvas.NewRectangle(p.surface)
	bg.CornerRadius = 10
	bg.StrokeColor = p.border
	bg.StrokeWidth = 1
	return container.NewStack(bg, container.NewPadded(content))
}

// row is one download card, updated in place each tick.
type row struct {
	id        string
	root      fyne.CanvasObject
	name      *widget.Label
	meta      *widget.Label
	right     *widget.Label
	bar       *bar
	primary   *widget.Button
	secondary *widget.Button
	lastBytes int64
	lastAt    time.Time
	bps       float64
	state     job.State
}

func (v *View) newRow(s job.Status) *row {
	r := &row{id: s.ID}
	r.name = widget.NewLabelWithStyle("", fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	r.name.Truncation = fyne.TextTruncateEllipsis
	r.meta = widget.NewLabel("")
	r.meta.SizeName = theme.SizeNameCaptionText
	r.meta.Importance = widget.LowImportance
	r.right = widget.NewLabel("")
	r.right.SizeName = theme.SizeNameCaptionText
	r.right.Alignment = fyne.TextAlignTrailing
	r.bar = newBar(pal(v.variantFn()))
	r.primary = widget.NewButton("", nil)
	r.primary.Importance = widget.LowImportance
	r.secondary = widget.NewButton("", nil)
	r.secondary.Importance = widget.LowImportance
	actions := container.NewHBox(r.primary, r.secondary)

	top := container.NewBorder(nil, nil, nil, actions, container.NewVBox(r.name, r.meta))
	bottom := container.NewBorder(nil, nil, nil, r.right, r.bar.root)
	r.root = v.card(container.NewVBox(top, bottom))
	r.state = -1
	return r
}

func (v *View) updateRow(r *row, s job.Status) {
	name := filepath.Base(s.Out)
	if name == "" || name == "." || name == "/" {
		name = "download"
	}
	host := ""
	if u, err := url.Parse(s.URL); err == nil {
		host = u.Host
	}
	r.name.SetText(name)

	// speed from byte delta between ticks
	now := time.Now()
	if !r.lastAt.IsZero() && s.Bytes >= r.lastBytes {
		dt := now.Sub(r.lastAt).Seconds()
		if dt > 0 {
			sample := float64(s.Bytes-r.lastBytes) / dt
			if r.bps == 0 {
				r.bps = sample
			} else {
				r.bps = 0.4*sample + 0.6*r.bps
			}
		}
	}
	r.lastBytes, r.lastAt = s.Bytes, now

	frac := 0.0
	if s.Total > 0 {
		frac = float64(s.Bytes) / float64(s.Total)
	}
	meta := host
	switch s.State {
	case job.Running:
		meta = host + "  ·  " + humanBytes(int64(r.bps)) + "/s"
		if s.Total > 0 && r.bps > 0 {
			meta += "  ·  " + eta(float64(s.Total-s.Bytes)/r.bps) + " left"
		}
	case job.Pending:
		meta = host + "  ·  queued"
	case job.Paused:
		meta = host + "  ·  paused"
	case job.Done:
		meta = host + "  ·  completed"
	case job.Failed:
		meta = host + "  ·  failed"
		if s.Err != nil {
			meta += ": " + s.Err.Error()
		}
	case job.Cancelled:
		meta = host + "  ·  cancelled"
	}
	if s.Retries > 0 && s.State == job.Running {
		meta += fmt.Sprintf("  ·  retry %d", s.Retries)
	}
	r.meta.SetText(meta)

	if s.Total > 0 {
		r.right.SetText(fmt.Sprintf("%s / %s  ·  %d%%", humanBytes(s.Bytes), humanBytes(s.Total), int(frac*100)))
	} else {
		r.right.SetText(humanBytes(s.Bytes))
	}
	p := pal(v.variantFn())
	fill := p.primary
	switch s.State {
	case job.Done:
		fill = p.success
	case job.Failed:
		fill = p.danger
	case job.Paused, job.Cancelled:
		fill = p.muted
	}
	r.bar.set(frac, fill)

	if s.State != r.state {
		r.state = s.State
		id := s.ID
		switch s.State {
		case job.Running, job.Pending:
			r.primary.SetText("Pause")
			r.primary.SetIcon(theme.MediaPauseIcon())
			r.primary.OnTapped = func() { _ = v.ctl.Pause(id); v.Refresh() }
			r.primary.Enable()
			r.secondary.SetText("Cancel")
			r.secondary.SetIcon(theme.CancelIcon())
			r.secondary.OnTapped = func() { _ = v.ctl.Cancel(id); v.Refresh() }
		case job.Paused:
			r.primary.SetText("Resume")
			r.primary.SetIcon(theme.MediaPlayIcon())
			r.primary.OnTapped = func() { _ = v.ctl.Resume(id); v.Refresh() }
			r.primary.Enable()
			r.secondary.SetText("Cancel")
			r.secondary.SetIcon(theme.CancelIcon())
			r.secondary.OnTapped = func() { _ = v.ctl.Cancel(id); v.Refresh() }
		case job.Done:
			out := s.Out
			r.primary.SetText("Show in Finder")
			r.primary.SetIcon(theme.FolderOpenIcon())
			r.primary.OnTapped = func() { v.ctl.Reveal(out) }
			r.primary.Enable()
			r.secondary.SetText("Remove")
			r.secondary.SetIcon(theme.DeleteIcon())
			r.secondary.OnTapped = func() { _ = v.ctl.Remove(id); v.Refresh() }
		default: // failed, cancelled
			r.primary.SetText("Retry")
			r.primary.SetIcon(theme.ViewRefreshIcon())
			r.primary.OnTapped = func() { _ = v.ctl.Resume(id); v.Refresh() }
			r.primary.Disable() // resume only applies to paused; kept visible for layout stability
			r.secondary.SetText("Remove")
			r.secondary.SetIcon(theme.DeleteIcon())
			r.secondary.OnTapped = func() { _ = v.ctl.Remove(id); v.Refresh() }
		}
	}
}

// refresh syncs rows with the queue: updates in place, adds/removes as needed.
func (v *View) refresh() {
	sts := v.ctl.Statuses()
	sort.Slice(sts, func(i, k int) bool { return sts[i].ID < sts[k].ID })
	seen := map[string]bool{}
	changed := false
	for _, s := range sts {
		seen[s.ID] = true
		r, ok := v.rows[s.ID]
		if !ok {
			r = v.newRow(s)
			v.rows[s.ID] = r
			v.list.Add(r.root)
			changed = true
		}
		v.updateRow(r, s)
	}
	for id, r := range v.rows {
		if !seen[id] {
			v.list.Remove(r.root)
			delete(v.rows, id)
			changed = true
		}
	}
	active := 0
	for _, s := range sts {
		if s.State == job.Running {
			active++
		}
	}
	switch {
	case len(sts) == 0:
		v.count.SetText("")
	case active == 0:
		v.count.SetText(fmt.Sprintf("%d in list", len(sts)))
	default:
		v.count.SetText(fmt.Sprintf("%d active  ·  %d in list", active, len(sts)))
	}
	if len(sts) == 0 {
		v.empty.Show()
	} else {
		v.empty.Hide()
	}
	if changed {
		v.list.Refresh()
	}
}

// bar is a thin, rounded progress bar drawn with two rectangles.
type bar struct {
	root  *fyne.Container
	track *canvas.Rectangle
	fill  *canvas.Rectangle
	frac  float64
}

type barLayout struct{ b *bar }

const barHeight float32 = 6

func (l *barLayout) MinSize([]fyne.CanvasObject) fyne.Size { return fyne.NewSize(80, barHeight) }

// Layout keeps the bar a fixed hairline, vertically centered in whatever
// height the surrounding layout hands it.
func (l *barLayout) Layout(objs []fyne.CanvasObject, size fyne.Size) {
	y := (size.Height - barHeight) / 2
	if y < 0 {
		y = 0
	}
	objs[0].Resize(fyne.NewSize(size.Width, barHeight))
	objs[0].Move(fyne.NewPos(0, y))
	w := float32(l.b.frac) * size.Width
	if w < 0 {
		w = 0
	}
	objs[1].Resize(fyne.NewSize(w, barHeight))
	objs[1].Move(fyne.NewPos(0, y))
}

func newBar(p palette) *bar {
	b := &bar{}
	b.track = canvas.NewRectangle(p.track)
	b.track.CornerRadius = 3
	b.fill = canvas.NewRectangle(p.primary)
	b.fill.CornerRadius = 3
	b.root = container.New(&barLayout{b: b}, b.track, b.fill)
	return b
}

// set updates the fill fraction and color in place.
func (b *bar) set(frac float64, fill color.Color) {
	if frac < 0 {
		frac = 0
	}
	if frac > 1 {
		frac = 1
	}
	b.frac = frac
	if b.fill.FillColor != fill {
		b.fill.FillColor = fill
		b.fill.Refresh()
	}
	b.root.Refresh()
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

func eta(sec float64) string {
	d := time.Duration(sec) * time.Second
	if d < time.Minute {
		return fmt.Sprintf("%ds", int(d.Seconds()))
	}
	if d < time.Hour {
		return fmt.Sprintf("%dm %ds", int(d.Minutes()), int(d.Seconds())%60)
	}
	return fmt.Sprintf("%dh %dm", int(d.Hours()), int(d.Minutes())%60)
}
