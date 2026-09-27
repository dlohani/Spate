package ui

import (
	"errors"
	"image/png"
	"os"
	"path/filepath"
	"testing"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/test"
	"fyne.io/fyne/v2/theme"

	"cascade/internal/job"
)

// fakeCtl feeds the view a fixed queue so the layout can be rendered headless.
type fakeCtl struct{ sts []job.Status }

func (f *fakeCtl) Statuses() []job.Status            { return f.sts }
func (f *fakeCtl) Add(string, string, int) error     { return nil }
func (f *fakeCtl) Pause(string) error                { return nil }
func (f *fakeCtl) Resume(string) error               { return nil }
func (f *fakeCtl) Cancel(string) error               { return nil }
func (f *fakeCtl) Remove(string) error               { return nil }
func (f *fakeCtl) ClearFinished() int                { return 0 }
func (f *fakeCtl) CancelAll()                        {}
func (f *fakeCtl) Reveal(string)                     {}

func sample() []job.Status {
	return []job.Status{
		{ID: "job-1", URL: "https://d8177.datatransfer.to/d/abc/nmac.to_pd270058628.zip", Out: "/Users/me/Downloads/nmac.to_pd270058628.zip", State: job.Running, Bytes: 156_000_000, Total: 160_789_966},
		{ID: "job-2", URL: "https://releases.ubuntu.com/26.04.1/ubuntu-26.04.1-desktop-amd64.iso", Out: "/Users/me/Downloads/ubuntu-26.04.1-desktop-amd64.iso", State: job.Running, Bytes: 1_540_000_000, Total: 6_482_409_472, Retries: 1},
		{ID: "job-3", URL: "https://download.microsoft.com/download/x/Windows11InstallationAssistant.exe", Out: "/Users/me/Downloads/Windows11InstallationAssistant.exe", State: job.Done, Bytes: 4_100_000, Total: 4_100_000},
		{ID: "job-4", URL: "https://example.com/report.pdf", Out: "/Users/me/Downloads/report.pdf", State: job.Paused, Bytes: 2_000_000, Total: 9_000_000},
		{ID: "job-5", URL: "https://send.now/", Out: "/Users/me/Downloads/download.bin", State: job.Failed, Err: errors.New("403 Forbidden")},
	}
}

// TestRenderSnapshot renders the UI headless and writes PNGs (light and dark)
// for visual review; it also guards against layout panics.
func TestRenderSnapshot(t *testing.T) {
	outDir := os.Getenv("CASCADE_UI_SNAPSHOT_DIR")
	if outDir == "" {
		outDir = t.TempDir()
	}
	for _, variant := range []struct {
		name string
		v    fyne.ThemeVariant
	}{{"light", theme.VariantLight}, {"dark", theme.VariantDark}} {
		a := test.NewApp()
		vv := variant.v
		a.Settings().SetTheme(ForcedVariant(vv)) // theme and view palette agree
		ctl := &fakeCtl{sts: sample()}
		view := Build(ctl, "/Users/me/Downloads", func() fyne.ThemeVariant { return vv })
		w := test.NewWindow(view.Root)
		w.Resize(fyne.NewSize(760, 560))
		view.Refresh()
		img := w.Canvas().Capture()
		p := filepath.Join(outDir, "cascade-"+variant.name+".png")
		f, err := os.Create(p)
		if err != nil {
			t.Fatal(err)
		}
		if err := png.Encode(f, img); err != nil {
			t.Fatal(err)
		}
		f.Close()
		t.Logf("snapshot: %s", p)
		w.Close()
	}
}
