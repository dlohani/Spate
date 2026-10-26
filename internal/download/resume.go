package download

import (
	"encoding/json"
	"os"
	"sync"
)

// controlExt is appended to the output path for the resume sidecar file.
const controlExt = ".cascade"

// Segment is one contiguous byte range [Start, End] and how much of it has been
// written to disk. Done is a count of bytes, so the next fetch resumes at
// Start+Done. Complete when Done == End-Start+1.
type Segment struct {
	Index int   `json:"index"`
	Start int64 `json:"start"`
	End   int64 `json:"end"`
	Done  int64 `json:"done"`
}

// Length returns the total size of the segment's range.
func (s Segment) Length() int64 { return s.End - s.Start + 1 }

// Remaining returns bytes still to fetch for this segment.
func (s Segment) Remaining() int64 { return s.Length() - s.Done }

// Complete reports whether the whole range has been written.
func (s Segment) Complete() bool { return s.Done >= s.Length() }

// layoutPart marks sidecars whose data lives at PartPath(out). Sidecars from
// before .part naming have no layout field; only for those may the engine
// treat a file at the final path as the partial.
const layoutPart = "part"

// Control is the persisted resume state, written next to the output file.
type Control struct {
	URL       string    `json:"url"`
	Total     int64     `json:"total"`
	Validator string    `json:"validator"` // ETag or Last-Modified at download start
	Conns     int       `json:"conns"`
	Layout    string    `json:"layout,omitempty"` // layoutPart, or "" for a pre-.part sidecar
	Segments  []Segment `json:"segments"`

	path     string       // sidecar path; not serialized
	mu       sync.Mutex   // guards Segments, assigned, splits
	assigned map[int]bool // segment index -> owned by a worker (not serialized)
	splits   int          // count of work-steal splits performed (not serialized)
}

// controlPath returns the sidecar path for a given output path.
func controlPath(outPath string) string { return outPath + controlExt }

// NewControl builds fresh resume state for a download.
func NewControl(outPath, url string, total int64, validator string, segs []Segment) *Control {
	return &Control{
		URL:       url,
		Total:     total,
		Validator: validator,
		Conns:     len(segs),
		Layout:    layoutPart,
		Segments:  segs,
		path:      controlPath(outPath),
		assigned:  make(map[int]bool),
	}
}

// LoadControl reads existing resume state for outPath. It returns (nil, nil)
// when no sidecar exists.
func LoadControl(outPath string) (*Control, error) {
	p := controlPath(outPath)
	data, err := os.ReadFile(p)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var c Control
	if err := json.Unmarshal(data, &c); err != nil {
		return nil, err
	}
	c.path = p
	c.assigned = make(map[int]bool)
	return &c, nil
}

// advance records that seg (by index) wrote n more bytes. Safe for concurrent
// use by segment workers.
func (c *Control) advance(index int, n int64) {
	c.mu.Lock()
	c.Segments[index].Done += n
	c.mu.Unlock()
}

// Save atomically persists the control file (write to temp, then rename).
func (c *Control) Save() error {
	c.mu.Lock()
	data, err := json.MarshalIndent(c, "", "  ")
	c.mu.Unlock()
	if err != nil {
		return err
	}
	tmp := c.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, c.path)
}

// Remove deletes the sidecar (called on successful completion).
func (c *Control) Remove() error {
	err := os.Remove(c.path)
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

// AllComplete reports whether every segment is fully written.
func (c *Control) AllComplete() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, s := range c.Segments {
		if !s.Complete() {
			return false
		}
	}
	return true
}

// BytesDone returns the sum of bytes written across all segments.
func (c *Control) BytesDone() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	var t int64
	for _, s := range c.Segments {
		t += s.Done
	}
	return t
}

// LegacyPartial reports whether the file at outPath is the partial data of a
// pre-.part download: a sidecar exists for it, that sidecar predates .part
// naming, and no .part file exists. Anything else at outPath (a finished
// download, a user's file) is never treated as partial data.
func LegacyPartial(outPath string) bool {
	if _, err := os.Stat(PartPath(outPath)); err == nil {
		return false
	}
	c, err := LoadControl(outPath)
	if err != nil || c == nil || c.Layout != "" {
		return false
	}
	_, err = os.Stat(outPath)
	return err == nil
}

// RemovePartial deletes a download's partial data (the .part file, or a
// legacy partial at the output path, see LegacyPartial) and its resume
// sidecar. A file at the output path that is not a legacy partial is left
// alone. Missing files are not an error. Used when a job is discarded.
func RemovePartial(outPath string) error {
	targets := []string{PartPath(outPath)}
	if LegacyPartial(outPath) {
		targets = append(targets, outPath)
	}
	targets = append(targets, controlPath(outPath))
	var first error
	for _, p := range targets {
		if err := os.Remove(p); err != nil && !os.IsNotExist(err) && first == nil {
			first = err
		}
	}
	return first
}
