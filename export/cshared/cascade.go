// Command cascade-cshared builds the download core as a C shared library
// (buildmode=c-shared), giving a stable C ABI that any platform UI can call:
// Flutter via dart:ffi, plus native desktop shells. It exposes the full app
// service (engine + queue + browser-capture endpoint + pairing) behind a
// handle, and passes structured data as JSON strings to stay language-neutral.
//
// Build (host platform):
//
//	go build -buildmode=c-shared -o libcascade.dylib ./export/cshared   # macOS
//	go build -buildmode=c-shared -o libcascade.so     ./export/cshared   # Linux
//	go build -buildmode=c-shared -o cascade.dll        ./export/cshared   # Windows
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"sync"
	"time"
	"unsafe"

	"cascade/internal/service"
	"cascade/internal/version"
)

// CascadeVersion returns the core's version ("0.0.0-dev" for an unstamped
// build). Caller frees.
//
//export CascadeVersion
func CascadeVersion() *C.char { return cstr(version.Version) }

var (
	reg    = map[int64]*service.Service{}
	regMu  sync.Mutex
	nextID int64
)

func lookup(h C.longlong) *service.Service {
	regMu.Lock()
	defer regMu.Unlock()
	return reg[int64(h)]
}

func cstr(s string) *C.char { return C.CString(s) }

// CascadeServiceStart starts the app service (engine, queue, capture endpoint,
// orphan resume). downloadDir "" selects the platform default. Returns a handle
// or 0 on error.
//
//export CascadeServiceStart
func CascadeServiceStart(maxConcurrent C.int, downloadDir *C.char) C.longlong {
	dir := ""
	if downloadDir != nil {
		dir = C.GoString(downloadDir)
	}
	s, err := service.Start(int(maxConcurrent), dir)
	if err != nil {
		return 0
	}
	return register(s)
}

// CascadeServiceStartJSON is CascadeServiceStart with options as JSON:
// {"maxConcurrent","downloadDir","settingsPath","allowMultiple"}. Omitted
// fields take the defaults. Returns a handle or 0 on error.
//
//export CascadeServiceStartJSON
func CascadeServiceStartJSON(spec *C.char) C.longlong {
	var in struct {
		MaxConcurrent int    `json:"maxConcurrent"`
		DownloadDir   string `json:"downloadDir"`
		SettingsPath  string `json:"settingsPath"`
		AllowMultiple bool   `json:"allowMultiple"`
	}
	if spec != nil {
		if err := json.Unmarshal([]byte(C.GoString(spec)), &in); err != nil {
			return 0
		}
	}
	s, err := service.StartWith(service.StartOpts{
		MaxConcurrent: in.MaxConcurrent, DownloadDir: in.DownloadDir,
		SettingsPath: in.SettingsPath, AllowMultiple: in.AllowMultiple,
	})
	if err != nil {
		return 0
	}
	return register(s)
}

func register(s *service.Service) C.longlong {
	regMu.Lock()
	nextID++
	id := nextID
	reg[id] = s
	regMu.Unlock()
	return C.longlong(id)
}

// CascadeServiceStop stops a service and releases its handle.
//
//export CascadeServiceStop
func CascadeServiceStop(handle C.longlong) {
	regMu.Lock()
	s := reg[int64(handle)]
	delete(reg, int64(handle))
	regMu.Unlock()
	if s != nil {
		s.Stop()
	}
}

// CascadeNew is kept for compatibility: a service with the default directory.
//
//export CascadeNew
func CascadeNew(maxConcurrent C.int) C.longlong { return CascadeServiceStart(maxConcurrent, nil) }

// CascadeClose is kept for compatibility (same as CascadeServiceStop).
//
//export CascadeClose
func CascadeClose(handle C.longlong) { CascadeServiceStop(handle) }

// CascadeInfoJSON returns {"addr","dir"} for the service (caller frees).
//
//export CascadeInfoJSON
func CascadeInfoJSON(handle C.longlong) *C.char {
	s := lookup(handle)
	if s == nil {
		return cstr("{}")
	}
	b, _ := json.Marshal(map[string]string{"addr": s.Addr, "dir": s.Dir})
	return cstr(string(b))
}

// CascadeAdd enqueues a download into dir ("" = default). Returns the job ID
// (caller frees) or "" on error.
//
//export CascadeAdd
func CascadeAdd(handle C.longlong, url, dir, sha256 *C.char, conns C.int) *C.char {
	s := lookup(handle)
	if s == nil {
		return cstr("")
	}
	d := ""
	if dir != nil {
		d = C.GoString(dir)
	}
	sh := ""
	if sha256 != nil {
		sh = C.GoString(sha256)
	}
	id, err := s.Add(C.GoString(url), d, sh, int(conns))
	if err != nil {
		return cstr("")
	}
	return cstr(id)
}

// CascadeAddJSON enqueues a download described by JSON:
// {"url","dir","sha256","conns","priority","startAt"} where startAt is a Unix
// timestamp in seconds (0 = now). Returns the job ID (caller frees) or "".
//
//export CascadeAddJSON
func CascadeAddJSON(handle C.longlong, spec *C.char) *C.char {
	s := lookup(handle)
	if s == nil || spec == nil {
		return cstr("")
	}
	var in struct {
		URL      string `json:"url"`
		Dir      string `json:"dir"`
		SHA256   string `json:"sha256"`
		Conns    int    `json:"conns"`
		Priority int    `json:"priority"`
		StartAt  int64  `json:"startAt"`
	}
	if err := json.Unmarshal([]byte(C.GoString(spec)), &in); err != nil {
		return cstr("")
	}
	o := service.AddOpts{URL: in.URL, Dir: in.Dir, SHA256: in.SHA256, Conns: in.Conns, Priority: in.Priority}
	if in.StartAt > 0 {
		o.StartAt = time.Unix(in.StartAt, 0)
	}
	id, err := s.AddWith(o)
	if err != nil {
		return cstr("")
	}
	return cstr(id)
}

// CascadeSettingsJSON returns the settings document (caller frees).
//
//export CascadeSettingsJSON
func CascadeSettingsJSON(handle C.longlong) *C.char {
	s := lookup(handle)
	if s == nil {
		return cstr("{}")
	}
	b, err := s.SettingsJSON()
	if err != nil {
		return cstr("{}")
	}
	return cstr(string(b))
}

// CascadeSettingsApply replaces and persists the settings from JSON. Returns
// 0 on success, -1 on a validation error.
//
//export CascadeSettingsApply
func CascadeSettingsApply(handle C.longlong, doc *C.char) C.int {
	s := lookup(handle)
	if s == nil || doc == nil {
		return -1
	}
	if err := s.ApplySettings([]byte(C.GoString(doc))); err != nil {
		return -1
	}
	return 0
}

// CascadeStartNow clears a pending job's scheduled start (0 ok, -1 error).
//
//export CascadeStartNow
func CascadeStartNow(handle C.longlong, jobID *C.char) C.int {
	return act(handle, jobID, func(s *service.Service, id string) error { return s.Mgr.StartNow(id) })
}

// CascadeCurrentLimit returns the bytes/sec cap in force (0 = unlimited).
//
//export CascadeCurrentLimit
func CascadeCurrentLimit(handle C.longlong) C.longlong {
	if s := lookup(handle); s != nil {
		return C.longlong(s.CurrentLimit())
	}
	return 0
}

func act(handle C.longlong, id *C.char, f func(*service.Service, string) error) C.int {
	s := lookup(handle)
	if s == nil {
		return -1
	}
	if err := f(s, C.GoString(id)); err != nil {
		return -1
	}
	return 0
}

// CascadePause pauses a job (0 ok, -1 error).
//
//export CascadePause
func CascadePause(handle C.longlong, jobID *C.char) C.int {
	return act(handle, jobID, func(s *service.Service, id string) error { return s.Mgr.Pause(id) })
}

// CascadeResume resumes a paused job (0 ok, -1 error).
//
//export CascadeResume
func CascadeResume(handle C.longlong, jobID *C.char) C.int {
	return act(handle, jobID, func(s *service.Service, id string) error { return s.Mgr.Resume(id) })
}

// CascadeCancel force-cancels a job (0 ok, -1 error).
//
//export CascadeCancel
func CascadeCancel(handle C.longlong, jobID *C.char) C.int {
	return act(handle, jobID, func(s *service.Service, id string) error { return s.Mgr.Cancel(id) })
}

// CascadeRemove removes a job from the queue (0 ok, -1 error).
//
//export CascadeRemove
func CascadeRemove(handle C.longlong, jobID *C.char) C.int {
	return act(handle, jobID, func(s *service.Service, id string) error { return s.Mgr.Remove(id) })
}

// CascadeClearFinished removes finished jobs; returns how many.
//
//export CascadeClearFinished
func CascadeClearFinished(handle C.longlong) C.int {
	s := lookup(handle)
	if s == nil {
		return 0
	}
	return C.int(s.Mgr.ClearFinished())
}

// CascadeCancelAll force-cancels every active job.
//
//export CascadeCancelAll
func CascadeCancelAll(handle C.longlong) {
	if s := lookup(handle); s != nil {
		s.Mgr.CancelAll()
	}
}

type statusJSON struct {
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

// CascadeStatusJSON returns a JSON array of job statuses (caller frees).
//
//export CascadeStatusJSON
func CascadeStatusJSON(handle C.longlong) *C.char {
	s := lookup(handle)
	if s == nil {
		return cstr("[]")
	}
	sts := s.Mgr.Statuses()
	out := make([]statusJSON, 0, len(sts))
	for _, st := range sts {
		j := statusJSON{ID: st.ID, URL: st.URL, Out: st.Out, State: st.State.String(),
			Priority: st.Priority, Bytes: st.Bytes, Total: st.Total, Retries: st.Retries}
		if !st.StartAt.IsZero() {
			j.StartAt = st.StartAt.Unix()
		}
		if st.Err != nil {
			j.Error = st.Err.Error()
		}
		out = append(out, j)
	}
	b, err := json.Marshal(out)
	if err != nil {
		return cstr("[]")
	}
	return cstr(string(b))
}

// CascadePairPending returns 1 while a browser extension is waiting for the
// user to allow or deny a connection; a shell polls this and shows a prompt.
//
//export CascadePairPending
func CascadePairPending(handle C.longlong) C.int {
	if s := lookup(handle); s != nil && s.PairPending() {
		return 1
	}
	return 0
}

// CascadeShowPending returns 1 (once) when another launch of the app asked
// this instance to show its window; a shell polls this and raises the window.
//
//export CascadeShowPending
func CascadeShowPending(handle C.longlong) C.int {
	if s := lookup(handle); s != nil && s.ShowPending() {
		return 1
	}
	return 0
}

// CascadeRequestShow asks an already running instance to show its window
// (used when CascadeServiceStart fails because one is running). Returns 1 if
// an instance answered.
//
//export CascadeRequestShow
func CascadeRequestShow() C.int {
	if service.RequestShow() {
		return 1
	}
	return 0
}

// CascadePairResolve answers the pending pairing request (ok != 0 allows).
//
//export CascadePairResolve
func CascadePairResolve(handle C.longlong, ok C.int) {
	if s := lookup(handle); s != nil {
		s.ResolvePair(ok != 0)
	}
}

// CascadeFreeString frees a string returned by this library.
//
//export CascadeFreeString
func CascadeFreeString(s *C.char) { C.free(unsafe.Pointer(s)) }

func main() {} // required for c-shared, never called
