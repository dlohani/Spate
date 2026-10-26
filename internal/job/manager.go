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
	"log/slog"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"cascade/internal/download"
)

// gateRetryDelay is how long a job waits before retrying after a policy gate
// (Wi-Fi/battery) blocked it.
const gateRetryDelay = 10 * time.Second

// isGateError reports whether err is a download policy-gate error.
func isGateError(err error) bool {
	var ge *download.GateError
	return errors.As(err, &ge)
}

// State is a job's lifecycle state.
type State int

const (
	Pending State = iota
	Running
	Paused
	Done
	Failed
	Cancelled
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
	case Cancelled:
		return "cancelled"
	default:
		return "unknown"
	}
}

// Terminal reports whether a state is final (won't run again).
func (s State) Terminal() bool { return s == Done || s == Failed || s == Cancelled }

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

	cancel      context.CancelFunc
	done        chan struct{} // closed when the current run's goroutine exits
	paused      bool          // a pause was requested for the current run
	cancelReq   bool          // a force-cancel was requested for the current run
	autoRetries int           // times re-queued after a transient (network) failure
	dl          *download.Downloader
}

// outputPath is where the job's data lives on disk (the spec's Out, or the
// name the engine derived). Caller holds m.mu.
func (j *Job) outputPath() string {
	if j.Out == "" && j.dl != nil {
		return j.dl.Output()
	}
	return j.Out
}

// Broken-download recovery: a job that fails on a transient network error is
// re-queued (resuming from disk) after failRetryDelay, up to maxAutoRetries.
const (
	failRetryDelay = 30 * time.Second
	maxAutoRetries = 50
)

// Status is an immutable snapshot of a job.
type Status struct {
	ID       string
	URL      string
	Out      string // output path
	State    State
	Priority int
	Err      error
	Bytes    int64
	Total    int64
	Retries  int       // automatic re-queues after transient failures
	StartAt  time.Time // scheduled start (zero = as soon as a slot is free)
}

// StatusJSON is the one wire shape for a job status, shared by every export
// (C ABI, gomobile, loopback /jobs) and mirrored by the Dart JobStatus model.
// Fields are added, never renamed or removed.
type StatusJSON struct {
	ID       string `json:"id"`
	URL      string `json:"url"`
	Out      string `json:"out"`
	State    string `json:"state"`
	Priority int    `json:"priority"`
	Bytes    int64  `json:"bytes"`
	Total    int64  `json:"total"`
	Retries  int    `json:"retries"`
	StartAt  int64  `json:"startAt,omitempty"` // Unix seconds; only for scheduled jobs
	Error    string `json:"error,omitempty"`
}

// JSON converts a Status to its wire shape.
func (s Status) JSON() StatusJSON {
	j := StatusJSON{ID: s.ID, URL: s.URL, Out: s.Out, State: s.State.String(),
		Priority: s.Priority, Bytes: s.Bytes, Total: s.Total, Retries: s.Retries}
	if !s.StartAt.IsZero() {
		j.StartAt = s.StartAt.Unix()
	}
	if s.Err != nil {
		j.Error = s.Err.Error()
	}
	return j
}

// StatusesJSON converts a status list to wire shapes (never nil, so it
// marshals as [] rather than null).
func StatusesJSON(sts []Status) []StatusJSON {
	out := make([]StatusJSON, 0, len(sts))
	for _, s := range sts {
		out = append(out, s.JSON())
	}
	return out
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
	version atomic.Uint64  // bumped on every queue change (see Version)

	startGate func() bool // optional: may queued jobs start right now?
	shutdown  bool        // Shutdown called: nothing starts, interruptions become Pending
}

// gateRecheck is how often the loop re-evaluates a closed start gate.
const gateRecheck = 30 * time.Second

// New returns a Manager that runs at most maxConcurrent downloads at once.
func New(maxConcurrent int) *Manager {
	if maxConcurrent < 1 {
		maxConcurrent = 1
	}
	m := &Manager{
		jobs:   make(map[string]*Job),
		max:    maxConcurrent,
		notify: make(chan struct{}, 1),
	}
	m.version.Store(1)
	return m
}

// Version is a counter that advances whenever the queue changes: a job is
// added, removed or changes state. Callers that poll (a UI, the queue
// persister) compare it with the value they saw last and skip work when it
// is unchanged. Progress bytes do not bump it.
func (m *Manager) Version() uint64 { return m.version.Load() }

// Record is the serialisable view of a queued job: what is needed to put it
// back as it was after a restart. Running jobs are recorded as pending (they
// resume from disk); terminal jobs are not recorded.
type Record struct {
	ID            string            `json:"id"`
	URL           string            `json:"url"`
	Out           string            `json:"out"`
	Priority      int               `json:"priority,omitempty"`
	StartAt       time.Time         `json:"startAt,omitempty"`
	Paused        bool              `json:"paused,omitempty"`
	Conns         int               `json:"conns,omitempty"`
	SHA256        string            `json:"sha256,omitempty"`
	Headers       map[string]string `json:"headers,omitempty"`
	Cookie        string            `json:"cookie,omitempty"`
	BasicUser     string            `json:"basicUser,omitempty"`
	BasicPassword string            `json:"basicPassword,omitempty"`
}

// Records returns the non-terminal jobs (pending, running, paused) in
// insertion order, as Records.
func (m *Manager) Records() []Record {
	m.mu.Lock()
	defer m.mu.Unlock()
	jobs := make([]*Job, 0, len(m.jobs))
	for _, j := range m.jobs {
		if !j.state.Terminal() {
			jobs = append(jobs, j)
		}
	}
	sort.Slice(jobs, func(i, k int) bool { return jobs[i].seq < jobs[k].seq })
	out := make([]Record, 0, len(jobs))
	for _, j := range jobs {
		o := j.Options
		r := Record{ID: j.ID, URL: j.URL, Out: j.outputPath(), Priority: j.Priority, StartAt: j.StartAt,
			Paused: j.state == Paused || j.paused, Conns: o.Conns, SHA256: o.SHA256, Cookie: o.Cookie,
			BasicUser: o.BasicUser, BasicPassword: o.BasicPassword}
		if len(o.Headers) > 0 {
			r.Headers = make(map[string]string, len(o.Headers))
			for k, v := range o.Headers {
				r.Headers[k] = v
			}
		}
		out = append(out, r)
	}
	return out
}

// AddRecord re-enqueues a job from a Record. base supplies the engine options
// the record does not carry (shared limiter, gate); the record's request
// customisation is copied onto it and Resume is set so a partial file on disk
// is continued. A record marked Paused is added in the Paused state.
func (m *Manager) AddRecord(r Record, base download.Options) (string, error) {
	base.Conns, base.SHA256, base.Cookie = r.Conns, r.SHA256, r.Cookie
	base.BasicUser, base.BasicPassword = r.BasicUser, r.BasicPassword
	base.Resume = true
	if len(r.Headers) > 0 {
		base.Headers = make(map[string]string, len(r.Headers))
		for k, v := range r.Headers {
			base.Headers[k] = v
		}
	}
	spec := Spec{ID: r.ID, URL: r.URL, Out: r.Out, Options: base, Priority: r.Priority, StartAt: r.StartAt}
	state := Pending
	if r.Paused {
		state = Paused
	}
	return m.add(spec, state)
}

// Add enqueues a download and returns its job ID.
func (m *Manager) Add(s Spec) (string, error) { return m.add(s, Pending) }

func (m *Manager) add(s Spec, state State) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if s.ID == "" {
		s.ID = fmt.Sprintf("job-%d", m.seqNext+1)
	}
	if _, exists := m.jobs[s.ID]; exists {
		return "", fmt.Errorf("job %q already exists", s.ID)
	}
	j := &Job{Spec: s, seq: m.seqNext, state: state}
	m.seqNext++
	// A restored ID ("job-7") must not be handed out again by the generator.
	var n int
	if _, err := fmt.Sscanf(s.ID, "job-%d", &n); err == nil && n >= m.seqNext {
		m.seqNext = n
	}
	m.jobs[s.ID] = j
	m.signal()
	slog.Info("job added", "id", s.ID, "url", s.URL, "out", s.Out, "state", state.String(), "priority", s.Priority, "startAt", s.StartAt)
	return s.ID, nil
}

// logTransition records a state change (caller holds m.mu or is in the run
// goroutine epilogue, which holds it too).
func logTransition(j *Job, from State, why string) {
	attrs := []any{"id", j.ID, "from", from.String(), "to", j.state.String()}
	if why != "" {
		attrs = append(attrs, "why", why)
	}
	if j.err != nil {
		attrs = append(attrs, "err", j.err.Error())
	}
	if j.state == Pending && !j.StartAt.IsZero() {
		attrs = append(attrs, "retryAt", j.StartAt)
	}
	slog.Info("job", attrs...)
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
		logTransition(j, Pending, "pause")
	default:
		return fmt.Errorf("job %q is %s, cannot pause", id, j.state)
	}
	m.signal()
	return nil
}

// Cancel force-cancels a job. A running job is stopped (partial file and its
// .cascade sidecar remain on disk); a pending or paused job is marked cancelled.
func (m *Manager) Cancel(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	j, ok := m.jobs[id]
	if !ok {
		return fmt.Errorf("no such job %q", id)
	}
	switch j.state {
	case Running:
		j.cancelReq = true
		if j.cancel != nil {
			j.cancel()
		}
	case Pending, Paused:
		from := j.state
		j.state = Cancelled
		logTransition(j, from, "cancel")
	default:
		return fmt.Errorf("job %q is %s, cannot cancel", id, j.state)
	}
	m.signal()
	return nil
}

// Remove cancels a job if it is still active and deletes it from the queue.
// Files on disk are kept (a partial download stays resumable, e.g. by
// re-adding the same link); see Discard to delete them.
func (m *Manager) Remove(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	j, ok := m.jobs[id]
	if !ok {
		return fmt.Errorf("no such job %q", id)
	}
	if j.state == Running && j.cancel != nil {
		j.cancelReq = true
		j.cancel() // running goroutine will decrement the running counter
	}
	delete(m.jobs, id)
	m.signal()
	slog.Info("job removed", "id", id, "state", j.state.String())
	return nil
}

// Discard removes a job from the queue and deletes its partial download from
// disk (the output file and the resume sidecar), stopping it first if it is
// running. A finished download's file is never deleted: for Done jobs this
// is the same as Remove.
func (m *Manager) Discard(id string) error {
	m.mu.Lock()
	j, ok := m.jobs[id]
	if !ok {
		m.mu.Unlock()
		return fmt.Errorf("no such job %q", id)
	}
	if j.state == Done {
		delete(m.jobs, id)
		m.mu.Unlock()
		m.signal()
		return nil
	}
	var done chan struct{}
	if j.state == Running && j.cancel != nil {
		j.cancelReq = true
		j.cancel()
		done = j.done
	}
	out := j.outputPath()
	delete(m.jobs, id)
	m.mu.Unlock()
	m.signal()
	slog.Info("job discarded", "id", id, "out", out)
	// Wait for the writer goroutine to close the file before deleting it, so
	// a final sidecar flush cannot resurrect what we just removed.
	if done != nil {
		<-done
	}
	if out == "" {
		return nil
	}
	return download.RemovePartial(out)
}

// ClearFinished removes all terminal jobs (done, failed, cancelled) from the
// queue and returns how many were removed. Failed and cancelled jobs leave
// the list for good, so their partial files are deleted; finished files stay.
func (m *Manager) ClearFinished() int {
	m.mu.Lock()
	n := 0
	var partials []string
	for id, j := range m.jobs {
		if j.state.Terminal() {
			if j.state != Done {
				if out := j.outputPath(); out != "" {
					partials = append(partials, out)
				}
			}
			delete(m.jobs, id)
			n++
		}
	}
	m.mu.Unlock()
	m.signal()
	for _, out := range partials {
		_ = download.RemovePartial(out)
	}
	return n
}

// CancelAll force-cancels every active job but leaves them in the list (as
// cancelled) so their partial state is visible.
func (m *Manager) CancelAll() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, j := range m.jobs {
		switch j.state {
		case Running:
			j.cancelReq = true
			if j.cancel != nil {
				j.cancel()
			}
		case Pending, Paused:
			j.state = Cancelled
		}
	}
	m.signal()
}

// StartNow clears a pending job's scheduled start so it runs as soon as a slot
// is free.
func (m *Manager) StartNow(id string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	j, ok := m.jobs[id]
	if !ok {
		return fmt.Errorf("no such job %q", id)
	}
	if j.state != Pending {
		return fmt.Errorf("job %q is %s, not pending", id, j.state)
	}
	j.StartAt = time.Time{}
	m.signal()
	return nil
}

// Shutdown stops every running download and waits for the goroutines to
// exit. Interrupted jobs become Pending with Resume set (they continue next
// start) rather than Failed, and no new job starts afterwards. Call it before
// persisting the queue for the last time; cancelling the Serve context
// afterwards is still required to end the loop.
func (m *Manager) Shutdown() {
	m.mu.Lock()
	m.shutdown = true
	for _, j := range m.jobs {
		if j.state == Running && j.cancel != nil {
			j.cancel()
		}
	}
	m.mu.Unlock()
	m.signal()
	m.wg.Wait()
}

// SetStartGate installs a policy consulted before any queued job starts (e.g.
// a "download window"); running jobs are unaffected. nil removes it.
func (m *Manager) SetStartGate(gate func() bool) {
	m.mu.Lock()
	m.startGate = gate
	m.mu.Unlock()
	m.signal()
}

// SetMaxConcurrent changes how many downloads run at once. Raising it starts
// eligible pending jobs; lowering it lets running jobs finish (no preemption).
func (m *Manager) SetMaxConcurrent(n int) {
	if n < 1 {
		n = 1
	}
	m.mu.Lock()
	m.max = n
	m.mu.Unlock()
	m.signal()
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
	logTransition(j, Paused, "resume")
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
	st := Status{ID: j.ID, URL: j.URL, Out: j.Out, State: j.state, Priority: j.Priority,
		Err: j.err, Retries: j.autoRetries, StartAt: j.StartAt}
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
func (m *Manager) Run(ctx context.Context) error { return m.drive(ctx, true) }

// Serve drives the queue indefinitely, processing jobs as they are added, and
// returns only when ctx is cancelled. Use this when embedding the manager as a
// long-lived background service (e.g. a mobile/desktop app).
func (m *Manager) Serve(ctx context.Context) error { return m.drive(ctx, false) }

func (m *Manager) drive(ctx context.Context, exitOnDrain bool) error {
	for {
		m.mu.Lock()
		if exitOnDrain && m.allTerminalLocked() {
			err := m.firstErrLocked()
			m.mu.Unlock()
			return err
		}
		m.startEligibleLocked(ctx)
		wake := m.nextScheduledLocked()
		if m.startGate != nil && !m.startGate() {
			if w := time.Now().Add(gateRecheck); wake.IsZero() || w.Before(wake) {
				wake = w
			}
		}
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
	if m.shutdown {
		return
	}
	if m.startGate != nil && !m.startGate() {
		return // outside the download window; drive() re-checks periodically
	}
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
	j.done = make(chan struct{})
	done := j.done
	m.running++
	m.wg.Add(1)
	m.version.Add(1) // pending -> running

	go func() {
		defer m.wg.Done()
		defer close(done)
		err := j.dl.Run(jctx)
		cancel()

		m.mu.Lock()
		m.running--
		why := ""
		switch {
		case err == nil:
			j.state = Done
			j.err = nil
		case j.cancelReq && errors.Is(err, context.Canceled):
			j.state = Cancelled
			j.err = nil
			why = "cancel"
		case j.paused && errors.Is(err, context.Canceled):
			j.state = Paused
			j.err = nil
			why = "pause"
		case m.shutdown && errors.Is(err, context.Canceled):
			j.Options.Resume = true
			j.state = Pending
			j.err = nil
			why = "shutdown"
		case isGateError(err):
			why = "gate"
			// Policy (Wi-Fi/battery) blocked it; re-queue to retry when
			// conditions may have changed, continuing from disk.
			j.Options.Resume = true
			j.state = Pending
			j.StartAt = time.Now().Add(gateRetryDelay)
			j.err = err
		case download.IsTransient(err) && j.autoRetries < maxAutoRetries:
			// Network gave out (connection resets, corrupted TLS records, 5xx)
			// beyond the engine's own retry window: keep the job alive and
			// resume from disk after a pause instead of failing the download.
			j.autoRetries++
			j.Options.Resume = true
			j.state = Pending
			j.StartAt = time.Now().Add(failRetryDelay)
			j.err = err
			why = fmt.Sprintf("transient, retry %d/%d", j.autoRetries, maxAutoRetries)
		default:
			j.state = Failed
			j.err = err
		}
		j.cancel = nil
		logTransition(j, Running, why)
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
		if !j.state.Terminal() {
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

// signal wakes the Run loop without blocking and marks the queue changed.
func (m *Manager) signal() {
	m.version.Add(1)
	select {
	case m.notify <- struct{}{}:
	default:
	}
}
