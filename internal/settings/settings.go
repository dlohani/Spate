// Package settings holds Spate's persisted user preferences: where downloads
// go (base folder, category and per-site destination rules), bandwidth limits
// with time windows, the queue's download window, and recurring downloads.
// It is pure policy: the service applies it to the engine and queue.
package settings

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"spate/internal/paths"
)

// Category routes files by extension into a folder (relative to the base
// download folder unless absolute). First matching category wins.
type Category struct {
	Name       string   `json:"name"`
	Extensions []string `json:"extensions"` // lower-case, without dot
	Dir        string   `json:"dir"`
}

// SiteRule routes downloads from a host (exact or any subdomain) to a folder.
type SiteRule struct {
	Host string `json:"host"`
	Dir  string `json:"dir"`
}

// Window is a time-of-day range on given weekdays (0=Sunday). Empty Days means
// every day. From/To are "HH:MM" local time; From > To spans midnight.
type Window struct {
	Days []int  `json:"days,omitempty"`
	From string `json:"from"`
	To   string `json:"to"`
}

// LimitWindow applies a different speed limit inside a Window.
type LimitWindow struct {
	Window
	BytesPerSec int64 `json:"bytesPerSec"` // 0 = unlimited inside the window
}

// Limits is the bandwidth policy: a default cap plus scheduled overrides.
type Limits struct {
	BytesPerSec int64         `json:"bytesPerSec"` // 0 = unlimited
	Windows     []LimitWindow `json:"windows,omitempty"`
}

// QueueWindow restricts when queued downloads may start (running ones finish).
type QueueWindow struct {
	Enabled bool `json:"enabled"`
	Window
}

// Recurring re-downloads a URL on a fixed cadence.
type Recurring struct {
	ID      string    `json:"id"`
	URL     string    `json:"url"`
	Dir     string    `json:"dir,omitempty"`
	Every   string    `json:"every"` // "hourly" | "daily" | "weekly"
	NextAt  time.Time `json:"nextAt"`
	Enabled bool      `json:"enabled"`
}

// Settings is the whole persisted document.
type Settings struct {
	DownloadDir        string      `json:"downloadDir"`
	OrganizeByCategory bool        `json:"organizeByCategory"`
	Categories         []Category  `json:"categories"`
	SiteRules          []SiteRule  `json:"siteRules"`
	Limits             Limits      `json:"limits"`
	QueueWindow        QueueWindow `json:"queueWindow"`
	Recurring          []Recurring `json:"recurring"`
	MaxConcurrent      int         `json:"maxConcurrent"`

	mu sync.Mutex `json:"-"`
}

// DefaultCategories is the starting set; users can edit it.
func DefaultCategories() []Category {
	return []Category{
		{Name: "Video", Extensions: []string{"mp4", "mkv", "avi", "mov", "webm", "m4v", "wmv", "flv"}, Dir: "Video"},
		{Name: "Audio", Extensions: []string{"mp3", "flac", "wav", "aac", "m4a", "ogg", "opus"}, Dir: "Audio"},
		{Name: "Images", Extensions: []string{"jpg", "jpeg", "png", "gif", "webp", "svg", "heic", "bmp", "tiff"}, Dir: "Images"},
		{Name: "Documents", Extensions: []string{"pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "epub", "csv", "md"}, Dir: "Documents"},
		{Name: "Archives", Extensions: []string{"zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst"}, Dir: "Archives"},
		{Name: "Programs", Extensions: []string{"exe", "msi", "dmg", "pkg", "deb", "rpm", "apk", "appimage"}, Dir: "Programs"},
		{Name: "Disk Images", Extensions: []string{"iso", "img", "vhd", "vmdk", "qcow2"}, Dir: "Disk Images"},
	}
}

// Default returns settings for a fresh install with downloadDir as the base.
func Default(downloadDir string) *Settings {
	return &Settings{
		DownloadDir:        downloadDir,
		OrganizeByCategory: false,
		Categories:         DefaultCategories(),
		MaxConcurrent:      3,
	}
}

// Path is the settings file location under the user config dir (migrating a
// previous install's files on the way, see internal/paths).
func Path() (string, error) {
	dir, err := paths.ConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "settings.json"), nil
}

// Load reads the settings file, returning Default(downloadDir) if absent.
func Load(path, downloadDir string) (*Settings, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return Default(downloadDir), nil
		}
		return nil, err
	}
	s := Default(downloadDir)
	if err := json.Unmarshal(b, s); err != nil {
		return nil, fmt.Errorf("settings: %w", err)
	}
	if s.DownloadDir == "" {
		s.DownloadDir = downloadDir
	}
	if s.MaxConcurrent <= 0 {
		s.MaxConcurrent = 3
	}
	return s, nil
}

// Save writes the settings atomically: a uniquely named temp file beside the
// target (so concurrent saves cannot rename each other's half-written file),
// mode 0600, then rename.
func (s *Settings) Save(path string) error {
	s.mu.Lock()
	b, err := json.MarshalIndent(s, "", "  ")
	s.mu.Unlock()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "settings-*.tmp")
	if err != nil {
		return err
	}
	name := tmp.Name()
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		os.Remove(name)
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		os.Remove(name)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(name)
		return err
	}
	return os.Rename(name, path)
}

// JSON returns the settings document.
func (s *Settings) JSON() ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return json.MarshalIndent(s, "", "  ")
}

// Apply updates the settings from a JSON document (validated). Fields omitted
// from the document keep their current values; a field present as an empty
// list clears that list.
func (s *Settings) Apply(b []byte) error {
	in := s.Snapshot() // omitted fields keep current values
	if err := json.Unmarshal(b, &in); err != nil {
		return fmt.Errorf("settings: %w", err)
	}
	for _, w := range in.Limits.Windows {
		if err := w.validate(); err != nil {
			return err
		}
	}
	if in.QueueWindow.Enabled {
		if err := in.QueueWindow.Window.validate(); err != nil {
			return err
		}
	}
	for i := range in.Categories {
		for j, e := range in.Categories[i].Extensions {
			in.Categories[i].Extensions[j] = strings.ToLower(strings.TrimPrefix(e, "."))
		}
	}
	for i := range in.Recurring {
		if in.Recurring[i].ID == "" {
			in.Recurring[i].ID = fmt.Sprintf("rec-%d", time.Now().UnixNano())
		}
		if _, err := interval(in.Recurring[i].Every); err != nil {
			return err
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if in.DownloadDir == "" {
		in.DownloadDir = s.DownloadDir
	}
	if in.MaxConcurrent <= 0 {
		in.MaxConcurrent = s.MaxConcurrent
	}
	s.DownloadDir, s.OrganizeByCategory, s.Categories, s.SiteRules = in.DownloadDir, in.OrganizeByCategory, in.Categories, in.SiteRules
	s.Limits, s.QueueWindow, s.Recurring, s.MaxConcurrent = in.Limits, in.QueueWindow, in.Recurring, in.MaxConcurrent
	return nil
}

// Resolve picks the destination folder for a download: a per-site rule wins,
// then the file's category (when organizing is on), else the base folder.
func (s *Settings) Resolve(rawURL, filename string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	base := s.DownloadDir
	host := ""
	if u, err := url.Parse(rawURL); err == nil {
		host = strings.ToLower(u.Hostname())
	}
	for _, r := range s.SiteRules {
		if hostMatches(host, r.Host) {
			return abs(r.Dir, base)
		}
	}
	if s.OrganizeByCategory {
		if c := s.categoryFor(filename); c != nil {
			return abs(c.Dir, base)
		}
	}
	return base
}

// CategoryName returns the matching category for a filename ("" if none).
func (s *Settings) CategoryName(filename string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if c := s.categoryFor(filename); c != nil {
		return c.Name
	}
	return ""
}

func (s *Settings) categoryFor(filename string) *Category {
	ext := strings.ToLower(strings.TrimPrefix(path.Ext(filename), "."))
	if ext == "" {
		return nil
	}
	for i := range s.Categories {
		for _, e := range s.Categories[i].Extensions {
			if e == ext {
				return &s.Categories[i]
			}
		}
	}
	return nil
}

// EffectiveLimit returns the bytes/sec cap in force at now (0 = unlimited):
// the first matching limit window, else the default cap.
func (s *Settings) EffectiveLimit(now time.Time) int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, w := range s.Limits.Windows {
		if w.contains(now) {
			return w.BytesPerSec
		}
	}
	return s.Limits.BytesPerSec
}

// MayStart reports whether queued downloads may start at now (queue window).
func (s *Settings) MayStart(now time.Time) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.QueueWindow.Enabled {
		return true
	}
	return s.QueueWindow.Window.contains(now)
}

// Due returns enabled recurring downloads whose NextAt has passed, advancing
// each one's NextAt past now. The caller enqueues them and saves.
func (s *Settings) Due(now time.Time) []Recurring {
	s.mu.Lock()
	defer s.mu.Unlock()
	var due []Recurring
	for i := range s.Recurring {
		r := &s.Recurring[i]
		if !r.Enabled || r.NextAt.IsZero() || r.NextAt.After(now) {
			continue
		}
		due = append(due, *r)
		for !r.NextAt.After(now) {
			r.NextAt = advance(r.NextAt, r.Every)
		}
	}
	return due
}

// advance moves a recurrence to its next occurrence. Daily and weekly step
// by calendar days in the local zone so "every day at 09:00" stays at 09:00
// across a daylight-saving change (a fixed 24h would drift by an hour);
// hourly steps by an hour of real time.
func advance(t time.Time, every string) time.Time {
	switch strings.ToLower(every) {
	case "daily":
		return t.In(time.Local).AddDate(0, 0, 1)
	case "weekly":
		return t.In(time.Local).AddDate(0, 0, 7)
	default:
		return t.Add(time.Hour)
	}
}

// Snapshot returns a copy safe to read without the lock (for UIs).
func (s *Settings) Snapshot() Settings {
	s.mu.Lock()
	defer s.mu.Unlock()
	return Settings{
		DownloadDir:        s.DownloadDir,
		OrganizeByCategory: s.OrganizeByCategory,
		Categories:         append([]Category(nil), s.Categories...),
		SiteRules:          append([]SiteRule(nil), s.SiteRules...),
		Limits: Limits{
			BytesPerSec: s.Limits.BytesPerSec,
			Windows:     append([]LimitWindow(nil), s.Limits.Windows...),
		},
		QueueWindow:   s.QueueWindow,
		Recurring:     append([]Recurring(nil), s.Recurring...),
		MaxConcurrent: s.MaxConcurrent,
	}
}

func interval(every string) (time.Duration, error) {
	switch strings.ToLower(every) {
	case "hourly":
		return time.Hour, nil
	case "daily":
		return 24 * time.Hour, nil
	case "weekly":
		return 7 * 24 * time.Hour, nil
	}
	return 0, fmt.Errorf("settings: unknown recurrence %q (hourly, daily, weekly)", every)
}

func hostMatches(host, rule string) bool {
	rule = strings.ToLower(strings.TrimSpace(rule))
	if rule == "" || host == "" {
		return false
	}
	return host == rule || strings.HasSuffix(host, "."+rule)
}

func abs(dir, base string) string {
	if dir == "" {
		return base
	}
	if filepath.IsAbs(dir) {
		return dir
	}
	return filepath.Join(base, dir)
}

func (w Window) validate() error {
	if _, err := parseHM(w.From); err != nil {
		return err
	}
	if _, err := parseHM(w.To); err != nil {
		return err
	}
	for _, d := range w.Days {
		if d < 0 || d > 6 {
			return fmt.Errorf("settings: weekday %d out of range 0-6", d)
		}
	}
	return nil
}

// contains reports whether now falls inside the window (local time).
func (w Window) contains(now time.Time) bool {
	from, err1 := parseHM(w.From)
	to, err2 := parseHM(w.To)
	if err1 != nil || err2 != nil {
		return false
	}
	cur := now.Hour()*60 + now.Minute()
	day := int(now.Weekday())
	inDay := func(d int) bool {
		if len(w.Days) == 0 {
			return true
		}
		for _, x := range w.Days {
			if x == d {
				return true
			}
		}
		return false
	}
	if from <= to {
		return inDay(day) && cur >= from && cur < to
	}
	// spans midnight: the evening part belongs to today, the morning part to
	// the previous day's window
	if cur >= from {
		return inDay(day)
	}
	if cur < to {
		return inDay((day + 6) % 7)
	}
	return false
}

func parseHM(s string) (int, error) {
	var h, m int
	if _, err := fmt.Sscanf(strings.TrimSpace(s), "%d:%d", &h, &m); err != nil || h < 0 || h > 23 || m < 0 || m > 59 {
		return 0, fmt.Errorf("settings: bad time %q (want HH:MM)", s)
	}
	return h*60 + m, nil
}

// SortedCategoryNames is a helper for UIs.
func (s *Settings) SortedCategoryNames() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	names := make([]string, 0, len(s.Categories))
	for _, c := range s.Categories {
		names = append(names, c.Name)
	}
	sort.Strings(names)
	return names
}
