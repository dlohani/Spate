package settings

import (
	"path/filepath"
	"testing"
	"time"
)

func TestResolveRules(t *testing.T) {
	s := Default("/dl")
	s.OrganizeByCategory = true
	s.SiteRules = []SiteRule{{Host: "releases.ubuntu.com", Dir: "Linux ISOs"}, {Host: "example.org", Dir: "/abs/example"}}

	cases := []struct{ url, name, want string }{
		{"https://releases.ubuntu.com/x.iso", "x.iso", filepath.Join("/dl", "Linux ISOs")}, // site rule beats category
		{"https://cdn.example.org/a.zip", "a.zip", "/abs/example"},                        // subdomain matches, absolute dir
		{"https://host/movie.mkv", "movie.mkv", filepath.Join("/dl", "Video")},
		{"https://host/doc.PDF", "doc.PDF", filepath.Join("/dl", "Documents")}, // case-insensitive ext
		{"https://host/noext", "noext", "/dl"},
		{"https://host/x.unknownext", "x.unknownext", "/dl"},
	}
	for _, c := range cases {
		if got := s.Resolve(c.url, c.name); got != c.want {
			t.Errorf("Resolve(%s,%s)=%s want %s", c.url, c.name, got, c.want)
		}
	}
	s.OrganizeByCategory = false
	if got := s.Resolve("https://host/movie.mkv", "movie.mkv"); got != "/dl" {
		t.Errorf("organizing off: got %s", got)
	}
}

func TestLimitWindowsAndQueueWindow(t *testing.T) {
	s := Default("/dl")
	s.Limits = Limits{BytesPerSec: 0, Windows: []LimitWindow{
		{Window: Window{From: "09:00", To: "18:00", Days: []int{1, 2, 3, 4, 5}}, BytesPerSec: 500_000},
		{Window: Window{From: "22:00", To: "06:00"}, BytesPerSec: 0}, // spans midnight, unlimited
	}}
	mon10 := time.Date(2026, 9, 28, 10, 0, 0, 0, time.Local) // Monday
	sat10 := time.Date(2026, 9, 26, 10, 0, 0, 0, time.Local) // Saturday
	tue2 := time.Date(2026, 9, 29, 2, 0, 0, 0, time.Local)   // inside the midnight window
	if s.EffectiveLimit(mon10) != 500_000 {
		t.Errorf("weekday work hours should be capped")
	}
	if s.EffectiveLimit(sat10) != 0 {
		t.Errorf("saturday should be uncapped")
	}
	if s.EffectiveLimit(tue2) != 0 {
		t.Errorf("night window should be uncapped")
	}
	s.QueueWindow = QueueWindow{Enabled: true, Window: Window{From: "23:00", To: "07:00"}}
	if s.MayStart(mon10) {
		t.Errorf("queue window closed at 10:00")
	}
	if !s.MayStart(tue2) {
		t.Errorf("queue window open at 02:00")
	}
}

func TestRecurringDue(t *testing.T) {
	s := Default("/dl")
	now := time.Now()
	s.Recurring = []Recurring{
		{ID: "a", URL: "https://x/a", Every: "daily", NextAt: now.Add(-time.Hour), Enabled: true},
		{ID: "b", URL: "https://x/b", Every: "daily", NextAt: now.Add(time.Hour), Enabled: true},
		{ID: "c", URL: "https://x/c", Every: "daily", NextAt: now.Add(-time.Hour), Enabled: false},
	}
	due := s.Due(now)
	if len(due) != 1 || due[0].ID != "a" {
		t.Fatalf("due = %+v", due)
	}
	if !s.Recurring[0].NextAt.After(now) {
		t.Errorf("NextAt should advance past now")
	}
	if len(s.Due(now)) != 0 {
		t.Errorf("nothing should be due twice")
	}
}

func TestApplyValidatesAndPersists(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "settings.json")
	s := Default("/dl")
	if err := s.Apply([]byte(`{"downloadDir":"/d2","organizeByCategory":true,"categories":[{"name":"Vid","extensions":[".MP4"],"dir":"V"}],"limits":{"bytesPerSec":1000,"windows":[{"from":"9:00","to":"17:00","bytesPerSec":10}]},"queueWindow":{"enabled":true,"from":"22:00","to":"06:00"},"recurring":[{"url":"https://x/y","every":"weekly","nextAt":"2026-10-01T00:00:00Z","enabled":true}]}`)); err != nil {
		t.Fatal(err)
	}
	if s.Resolve("https://h/a.mp4", "a.mp4") != filepath.Join("/d2", "V") {
		t.Errorf("extension normalization failed")
	}
	if s.Recurring[0].ID == "" {
		t.Errorf("recurring id should be generated")
	}
	if err := s.Apply([]byte(`{"limits":{"windows":[{"from":"25:00","to":"1:00"}]}}`)); err == nil {
		t.Errorf("bad time should be rejected")
	}
	if err := s.Apply([]byte(`{"recurring":[{"url":"u","every":"fortnightly"}]}`)); err == nil {
		t.Errorf("bad recurrence should be rejected")
	}
	if err := s.Save(p); err != nil {
		t.Fatal(err)
	}
	back, err := Load(p, "/dl")
	if err != nil {
		t.Fatal(err)
	}
	if back.DownloadDir != "/d2" || !back.OrganizeByCategory || back.Limits.BytesPerSec != 1000 {
		t.Errorf("round trip mismatch: %+v", back.Snapshot())
	}
}
