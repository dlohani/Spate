// Package mobile is a gomobile-friendly facade over the download core, for
// building native Android (.aar) and iOS (.xcframework) bindings:
//
//	gomobile bind -target=android -o cascade.aar        ./mobile
//	gomobile bind -target=ios     -o Cascade.xcframework ./mobile
//
// The exported surface is restricted to gomobile-safe types (string, int, int64,
// bool, error, and pointers to structs defined here). Structured queries are
// returned as JSON strings so the same shape is shared with the C-ABI export.
// Platform concerns (Wi-Fi/battery gating via WorkManager, share intents,
// foreground service, notifications) live in the native shell, not here.
package mobile

import (
	"context"
	"encoding/json"

	"cascade/internal/download"
	"cascade/internal/job"
)

// Client is a long-lived download service. Construct it with NewClient.
type Client struct {
	mgr    *job.Manager
	cancel context.CancelFunc
}

// NewClient creates a client that runs at most maxConcurrent downloads at once
// and starts its background service loop.
func NewClient(maxConcurrent int) *Client {
	m := job.New(maxConcurrent)
	ctx, cancel := context.WithCancel(context.Background())
	go func() { _ = m.Serve(ctx) }()
	return &Client{mgr: m, cancel: cancel}
}

// Add enqueues a download and returns its job ID. sha256 may be empty; conns <= 0
// uses the engine default.
func (c *Client) Add(url, out, sha256 string, conns int) (string, error) {
	return c.mgr.Add(job.Spec{
		URL: url,
		Out: out,
		Options: download.Options{
			Conns:  conns,
			SHA256: sha256,
		},
	})
}

// Pause pauses a running or pending job.
func (c *Client) Pause(jobID string) error { return c.mgr.Pause(jobID) }

// Resume resumes a paused job, continuing from disk.
func (c *Client) Resume(jobID string) error { return c.mgr.Resume(jobID) }

// StatusJSON returns a JSON array of all job statuses. gomobile cannot export a
// slice of structs, so the shape is delivered as JSON (same schema as the C-ABI
// export): [{"id","state","priority","bytes","total","error"}].
func (c *Client) StatusJSON() string {
	sts := c.mgr.Statuses()
	out := make([]statusJSON, 0, len(sts))
	for _, s := range sts {
		sj := statusJSON{ID: s.ID, State: s.State.String(), Priority: s.Priority, Bytes: s.Bytes, Total: s.Total}
		if s.Err != nil {
			sj.Error = s.Err.Error()
		}
		out = append(out, sj)
	}
	data, err := json.Marshal(out)
	if err != nil {
		return "[]"
	}
	return string(data)
}

// Close stops the service loop.
func (c *Client) Close() { c.cancel() }

type statusJSON struct {
	ID       string `json:"id"`
	State    string `json:"state"`
	Priority int    `json:"priority"`
	Bytes    int64  `json:"bytes"`
	Total    int64  `json:"total"`
	Error    string `json:"error,omitempty"`
}
