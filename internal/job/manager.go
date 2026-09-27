// Package job provides a queue/scheduler around the download engine: multiple
// downloads with priorities, scheduled start times, a bounded number running at
// once, and per-job pause/resume.
//
// Pause is implemented by cancelling the running download (which leaves a
// resumable .cascade sidecar) and marking the job paused; resume re-queues it
// with the engine's Resume option, so it continues from where it stopped.
package job

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"sync"
	"time"

	"cascade/internal/download"
)

// State is a job's lifecycle state.
type State int

const (
	Pending State = iota
	Running
	Paused
	Done
	Failed
)

func (s State) String() string {
	switch s {
	case Pending:
		return "pending"
	case Running:
		return "running"
	case Paused:
		return "paused"
	case Done:
		return "done"
	case Failed:
		return "failed"
	default:
		return "unknown"
	}
}

// Spec describes a download to enqueue.
type Spec struct {
	ID       string           // unique; generated if empty
	URL      string           // source URL
	Out      string           // output path (may be empty; engine derives)
	Options  download.Options // per-download engine options
	Priority int              // higher runs first among eligible jobs
	StartAt  time.Time        // earliest start; zero = immediately eligible
}

// Job is the runtime state of an enqueued Spec.
type Job struct {
	Spec
	seq   int // insertion order, for stable tie-breaking
	state State
	err   error

	cancel  context.CancelFunc
	paused  bool // a pause was requested for the current run
	dl      *download.Downloader
}

// Status is an immutable snapshot of a job.
type Status struct {
	ID       string
	State    State
	Priority int
	Err      error
	Bytes    int64
	Total    int64
}

// Manager runs a set of jobs with bounded concurrency.
type Manager struct {
	mu      sync.Mutex
	jobs    map[string]*Job
	max     int
	running int
	seqNext int
	notify  chan struct{}
	wg      sync.WaitGroup // tracks running job goroutines
}

// New returns a Manager that runs at most maxConcurrent downloads at once.
func New(maxConcurrent int) *Manager {
	if maxConcurrent < 1 {
		maxConcurrent = 1
	}
	return &Manager{
		jobs:   make(map[string]*Job),
		max:    maxConcurrent,
		notify: make(chan struct{}, 1),
	}
}

// Add enqueues a download and returns its job ID.
func (m *Manager) Add(s Spec) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if s.ID == "" {
		s.ID = fmt.Sprintf("job-%d", m.seqNext+1)
	}
	if _, exists := m.jobs[s.ID]; exists {
		return "", fmt.Errorf("job %q already exists", s.ID)
	}
	j := &Job{Spec: s, seq: m.seqNext, state: Pending}
	m.seqNext++
	m.jobs[s.ID] = j
	m.signal()
	return s.ID, nil
}

// Pause requests that a running or pending job stop. A running job is cancelled
// (leaving resumable state); a pending job simply won't start.
func (m *Manager) Pause(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	j, ok := m.jobs[id]
	if !ok {
		return fmt.Errorf("no such job %q", id)
	}
	switch j.state {
	case Running:
		j.paused = true
		if j.cancel != nil {
			j.cancel()
		}
	case Pending:
		j.state = Paused
	default:
		return fmt.Errorf("job %q is %s, cannot pause", id, j.state)
	}
	m.signal()
	return nil
}

// Resume makes a paused job eligible to run again, continuing from disk.
func (m *Manager) Resume(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	j, ok := m.jobs[id]
	if !ok {
		return fmt.Errorf("no such job %q", id)
	}
	if j.state != Paused {
		return fmt.Errorf("job %q is %s, not paused", id, j.state)
	}
	j.Options.Resume = true
	j.paused = false
	j.state = Pending
	m.signal()
	return nil
}

// Status returns a snapshot of one job.
func (m *Manager) Status(id string) (Status, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	j, ok := m.jobs[id]
	if !ok {
		return Status{}, false
	}
	return m.statusLocked(j), true
}

// Statuses returns snapshots of all jobs, ordered by insertion.
func (m *Manager) Statuses() []Status {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Status, 0, len(m.jobs))
	for _, j := range m.jobs {
		out = append(out, m.statusLocked(j))
	}
	sort.Slice(out, func(i, k int) bool {
		return m.jobs[out[i].ID].seq < m.jobs[out[k].ID].seq
	})
	return out
}

func (m *Manager) statusLocked(j *Job) Status {
	st := Status{ID: j.ID, State: j.state, Priority: j.Priority, Err: j.err}
	if j.dl != nil {
		if meter := j.dl.Meter(); meter != nil {
			st.Bytes = meter.Done()
			st.Total = meter.Total()
		}
	}
	return st
}

// Run drives the queue until every job is terminal (Done or Failed), or ctx is
// cancelled. It returns the first job error, if any. Jobs left only in Paused
// state keep Run blocked until they are resumed or ctx is cancelled.
func (m *Manager) Run(ctx context.Context) error {
	for {
		m.mu.Lock()
		if m.allTerminalLocked() {
			err := m.firstErrLocked()
			m.mu.Unlock()
			return err
		}
		m.startEligibleLocked(ctx)
		wake := m.nextScheduledLocked()
		m.mu.Unlock()

		var timer *time.Timer
		var timerC <-chan time.Time
		if !wake.IsZero() {
			d := time.Until(wake)
			if d < 0 {
				d = 0
			}
			timer = time.NewTimer(d)
			timerC = timer.C
		}
		select {
		case <-ctx.Done():
			if timer != nil {
				timer.Stop()
			}
			m.cancelAll()
			m.waitIdle()
			return ctx.Err()
		case <-m.notify:
		case <-timerC:
		}
		if timer != nil {
			timer.Stop()
		}
	}
}

// startEligibleLocked launches as many eligible jobs as capacity allows, highest
// priority first (ties broken by insertion order). Caller holds m.mu.
func (m *Manager) startEligibleLocked(ctx context.Context) {
	now := time.Now()
	for m.running < m.max {
		var pick *Job
		for _, j := range m.jobs {
			if j.state != Pending {
				continue
			}
			if !j.StartAt.IsZero() && j.StartAt.After(now) {
				continue // not yet scheduled
			}
			if pick == nil || j.Priority > pick.Priority ||
				(j.Priority == pick.Priority && j.seq < pick.seq) {
				pick = j
			}
		}
		if pick == nil {
			return
		}
		m.launchLocked(ctx, pick)
	}
}

// launchLocked starts one job. Caller holds m.mu.
func (m *Manager) launchLocked(ctx context.Context, j *Job) {
	jctx, cancel := context.WithCancel(ctx)
	j.cancel = cancel
	j.state = Running
	j.err = nil
	j.dl = download.New(j.URL, j.Out, j.Options)
	m.running++
	m.wg.Add(1)

	go func() {
		defer m.wg.Done()
		err := j.dl.Run(jctx)
		cancel()

		m.mu.Lock()
		m.running--
		switch {
		case err == nil:
			j.state = Done
			j.err = nil
		case j.paused && errors.Is(err, context.Canceled):
			j.state = Paused
			j.err = nil
		default:
			j.state = Failed
			j.err = err
		}
		j.cancel = nil
		m.mu.Unlock()
		m.signal()
	}()
}

// nextScheduledLocked returns the earliest future StartAt among pending jobs, or
// the zero time if none are waiting on a schedule. Caller holds m.mu.
func (m *Manager) nextScheduledLocked() time.Time {
	var next time.Time
	now := time.Now()
	for _, j := range m.jobs {
		if j.state != Pending || j.StartAt.IsZero() || !j.StartAt.After(now) {
			continue
		}
		if next.IsZero() || j.StartAt.Before(next) {
			next = j.StartAt
		}
	}
	return next
}

func (m *Manager) allTerminalLocked() bool {
	for _, j := range m.jobs {
		if j.state != Done && j.state != Failed {
			return false
		}
	}
	return true
}

func (m *Manager) firstErrLocked() error {
	// Report a deterministic first error by insertion order.
	var jobs []*Job
	for _, j := range m.jobs {
		jobs = append(jobs, j)
	}
	sort.Slice(jobs, func(i, k int) bool { return jobs[i].seq < jobs[k].seq })
	for _, j := range jobs {
		if j.state == Failed && j.err != nil {
			return j.err
		}
	}
	return nil
}

func (m *Manager) cancelAll() {
	m.mu.Lock()
	for _, j := range m.jobs {
		if j.state == Running && j.cancel != nil {
			j.cancel()
		}
	}
	m.mu.Unlock()
}

// waitIdle blocks until all running job goroutines have finished.
func (m *Manager) waitIdle() { m.wg.Wait() }

// signal wakes the Run loop without blocking.
func (m *Manager) signal() {
	select {
	case m.notify <- struct{}{}:
	default:
	}
}
