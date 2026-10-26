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
	"errors"
	"sync"
	"time"
	"unsafe"

	"cascade/internal/job"
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

	errMu   sync.Mutex
	lastErr string // most recent failure reported by any export (see CascadeLastError)
)

// setErr records why the last call failed. Exports return 0, -1 or "" on
// failure; the text is available through CascadeLastError so a shell can show
// the reason (a corrupt settings file, an invalid URL) instead of guessing.
func setErr(err error) {
	errMu.Lock()
	if err != nil {
		lastErr = err.Error()
	} else {
		lastErr = ""
	}
	errMu.Unlock()
}

func lastErrorText() string {
	errMu.Lock()
	defer errMu.Unlock()
	return lastErr
}

// CascadeLastError returns the message of the most recent failed call in this
// library, or "" when the last call succeeded or nothing failed yet (calls
// that take a bad handle are the exception: they leave it as is). Caller
// frees. A failed CascadeServiceStart* reports here whether Cascade was
// already running (ErrAlreadyRunning's text) or something else went wrong.
//
//export CascadeLastError
func CascadeLastError() *C.char { return cstr(lastErrorText()) }

// startJSON is CascadeServiceStartJSON without the C types (testable).
func startJSON(spec string) int64 {
	var in struct {
		MaxConcurrent int    `json:"maxConcurrent"`
		DownloadDir   string `json:"downloadDir"`
		SettingsPath  string `json:"settingsPath"`
		AllowMultiple bool   `json:"allowMultiple"`
	}
	if spec != "" {
		if err := json.Unmarshal([]byte(spec), &in); err != nil {
			setErr(errors.New("start: bad options JSON: " + err.Error()))
			return 0
		}
	}
	s, err := service.StartWith(service.StartOpts{
		MaxConcurrent: in.MaxConcurrent, DownloadDir: in.DownloadDir,
		SettingsPath: in.SettingsPath, AllowMultiple: in.AllowMultiple,
	})
	if err != nil {
		setErr(err)
		return 0
	}
	setErr(nil)
	return int64(register(s))
}

func lookup(h C.longlong) *service.Service { return lookupID(int64(h)) }

func lookupID(h int64) *service.Service {
	regMu.Lock()
	defer regMu.Unlock()
	return reg[h]
}

// stopID is CascadeServiceStop without the C type (testable).
func stopID(h int64) {
	regMu.Lock()
	s := reg[h]
	delete(reg, h)
	regMu.Unlock()
	if s != nil {
		s.Stop()
	}
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
		setErr(err)
		return 0
	}
	setErr(nil)
	return register(s)
}

// CascadeServiceStartJSON is CascadeServiceStart with options as JSON:
// {"maxConcurrent","downloadDir","settingsPath","allowMultiple"}. Omitted
// fields take the defaults. Returns a handle or 0 on error.
//
//export CascadeServiceStartJSON
func CascadeServiceStartJSON(spec *C.char) C.longlong {
	js := ""
	if spec != nil {
		js = C.GoString(spec)
	}
	return C.longlong(startJSON(js))
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
func CascadeServiceStop(handle C.longlong) { stopID(int64(handle)) }

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
	b, _ := json.Marshal(map[string]string{"addr": s.Addr, "dir": s.Dir, "configDir": s.ConfigDir()})
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
		setErr(err)
		return cstr("")
	}
	setErr(nil)
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
		setErr(errors.New("add: bad spec JSON: " + err.Error()))
		return cstr("")
	}
	o := service.AddOpts{URL: in.URL, Dir: in.Dir, SHA256: in.SHA256, Conns: in.Conns, Priority: in.Priority}
	if in.StartAt > 0 {
		o.StartAt = time.Unix(in.StartAt, 0)
	}
	id, err := s.AddWith(o)
	if err != nil {
		setErr(err)
		return cstr("")
	}
	setErr(nil)
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
		setErr(err)
		return -1
	}
	setErr(nil)
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
		setErr(err)
		return -1
	}
	setErr(nil)
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

// CascadeRemove removes a job from the queue, keeping its files on disk
// (0 ok, -1 error).
//
//export CascadeRemove
func CascadeRemove(handle C.longlong, jobID *C.char) C.int {
	return act(handle, jobID, func(s *service.Service, id string) error { return s.Mgr.Remove(id) })
}

// CascadeDiscard removes a job from the queue and deletes its partial
// download (output file + resume sidecar), stopping it first if running. A
// finished download's file is kept (0 ok, -1 error).
//
//export CascadeDiscard
func CascadeDiscard(handle C.longlong, jobID *C.char) C.int {
	return act(handle, jobID, func(s *service.Service, id string) error { return s.Mgr.Discard(id) })
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

// CascadeStatusJSON returns a JSON array of job statuses (caller frees); the
// shape is job.StatusJSON, shared with the loopback /jobs route.
//
//export CascadeStatusJSON
func CascadeStatusJSON(handle C.longlong) *C.char {
	s := lookup(handle)
	if s == nil {
		return cstr("[]")
	}
	b, err := json.Marshal(job.StatusesJSON(s.Mgr.Statuses()))
	if err != nil {
		return cstr("[]")
	}
	return cstr(string(b))
}

// CascadeQueueVersion returns a counter that advances whenever the queue
// changes (a job added, removed or changing state; not progress bytes). A
// shell that polls compares it with the last value it saw and skips fetching
// and parsing the status list when nothing changed. 0 for a bad handle.
//
//export CascadeQueueVersion
func CascadeQueueVersion(handle C.longlong) C.ulonglong {
	if s := lookup(handle); s != nil {
		return C.ulonglong(s.Mgr.Version())
	}
	return 0
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
