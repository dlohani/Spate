package service

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"spate/internal/job"
)

// queueFileVersion is the on-disk format version of queue.json. A file from
// a newer version is refused (not guessed at) so a downgrade cannot corrupt it.
const queueFileVersion = 1

// persistTick is how often the queue is compared with what was last saved.
const persistTick = time.Second

// queueFile is the persisted queue: every non-terminal job as a job.Record,
// so pause state, schedule, priority and the request customisation a browser
// hand-off carried (cookies, referrer) all survive a restart.
type queueFile struct {
	Version int          `json:"version"`
	Jobs    []job.Record `json:"jobs"`
}

// queuePath is the queue file beside the settings document.
func queuePath(settingsPath string) string {
	return filepath.Join(filepath.Dir(settingsPath), "queue.json")
}

// saveQueue writes recs atomically (unique temp file, 0600, rename).
func saveQueue(path string, recs []job.Record) error {
	if recs == nil {
		recs = []job.Record{}
	}
	b, err := json.MarshalIndent(queueFile{Version: queueFileVersion, Jobs: recs}, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), "queue-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return err
	}
	return os.Rename(tmpName, path)
}

// loadQueue reads the queue file. A missing file is an empty queue (nil,
// nil); a malformed file or one written by a newer version is an error, and
// the caller starts with an empty queue rather than refusing to start.
func loadQueue(path string) ([]job.Record, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var qf queueFile
	if err := json.Unmarshal(b, &qf); err != nil {
		return nil, fmt.Errorf("queue: %w", err)
	}
	if qf.Version > queueFileVersion {
		return nil, fmt.Errorf("queue: file version %d is newer than this build supports (%d)", qf.Version, queueFileVersion)
	}
	return qf.Jobs, nil
}

// queuePersister saves the queue whenever its version changed since the last
// save, and once more, synchronously, when stopped.
type queuePersister struct {
	path string
	mgr  *job.Manager
	stop chan struct{}
	wg   sync.WaitGroup
	last uint64
}

func startQueuePersister(path string, mgr *job.Manager) *queuePersister {
	p := &queuePersister{path: path, mgr: mgr, stop: make(chan struct{}), last: mgr.Version()}
	p.wg.Add(1)
	go p.loop()
	return p
}

func (p *queuePersister) loop() {
	defer p.wg.Done()
	t := time.NewTicker(persistTick)
	defer t.Stop()
	for {
		select {
		case <-p.stop:
			return
		case <-t.C:
			if v := p.mgr.Version(); v != p.last {
				if err := saveQueue(p.path, p.mgr.Records()); err == nil {
					p.last = v
				}
			}
		}
	}
}

// Close stops the loop and writes the queue one final time. It must run
// before the manager is cancelled: cancellation turns running jobs terminal,
// and they would otherwise vanish from the file instead of resuming.
func (p *queuePersister) Close() error {
	close(p.stop)
	p.wg.Wait()
	return saveQueue(p.path, p.mgr.Records())
}
