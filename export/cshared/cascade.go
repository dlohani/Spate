// Command cascade-cshared builds the download core as a C shared library
// (buildmode=c-shared), giving a stable C ABI that any platform UI can call:
// Flutter via dart:ffi, plus native desktop shells. It exposes a small handle-
// based API and passes structured data as JSON strings to stay language-neutral.
//
// Build (host platform):
//
//	go build -buildmode=c-shared -o libcascade.dylib ./export/cshared   # macOS
//	go build -buildmode=c-shared -o libcascade.so     ./export/cshared   # Linux
//	go build -buildmode=c-shared -o cascade.dll        ./export/cshared   # Windows
//
// A libcascade.h header is emitted alongside the library.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"sync"
	"unsafe"

	"cascade/internal/download"
	"cascade/internal/job"
)

// clientState is one manager instance behind a handle.
type clientState struct {
	mgr    *job.Manager
	cancel context.CancelFunc
}

var (
	reg    = map[int64]*clientState{}
	regMu  sync.Mutex
	nextID int64
)

func lookup(h int64) *clientState {
	regMu.Lock()
	defer regMu.Unlock()
	return reg[h]
}

// CascadeNew creates a client that runs at most maxConcurrent downloads at once
// and starts its background service loop. Returns a handle, or 0 on error.
//
//export CascadeNew
func CascadeNew(maxConcurrent C.int) C.longlong {
	m := job.New(int(maxConcurrent))
	ctx, cancel := context.WithCancel(context.Background())
	go func() { _ = m.Serve(ctx) }()

	regMu.Lock()
	nextID++
	id := nextID
	reg[id] = &clientState{mgr: m, cancel: cancel}
	regMu.Unlock()
	return C.longlong(id)
}

// CascadeAdd enqueues a download. Returns the job ID (caller frees via
// CascadeFreeString), or an empty string on error.
//
//export CascadeAdd
func CascadeAdd(handle C.longlong, url, out, sha256 *C.char, conns C.int) *C.char {
	cs := lookup(int64(handle))
	if cs == nil {
		return C.CString("")
	}
	id, err := cs.mgr.Add(job.Spec{
		URL: C.GoString(url),
		Out: C.GoString(out),
		Options: download.Options{
			Conns:  int(conns),
			SHA256: C.GoString(sha256),
		},
	})
	if err != nil {
		return C.CString("")
	}
	return C.CString(id)
}

// CascadePause pauses a job. Returns 0 on success, -1 on error.
//
//export CascadePause
func CascadePause(handle C.longlong, jobID *C.char) C.int {
	cs := lookup(int64(handle))
	if cs == nil {
		return -1
	}
	if err := cs.mgr.Pause(C.GoString(jobID)); err != nil {
		return -1
	}
	return 0
}

// CascadeResume resumes a paused job. Returns 0 on success, -1 on error.
//
//export CascadeResume
func CascadeResume(handle C.longlong, jobID *C.char) C.int {
	cs := lookup(int64(handle))
	if cs == nil {
		return -1
	}
	if err := cs.mgr.Resume(C.GoString(jobID)); err != nil {
		return -1
	}
	return 0
}

type statusJSON struct {
	ID       string `json:"id"`
	State    string `json:"state"`
	Priority int    `json:"priority"`
	Bytes    int64  `json:"bytes"`
	Total    int64  `json:"total"`
	Error    string `json:"error,omitempty"`
}

// CascadeStatusJSON returns a JSON array of all job statuses (caller frees via
// CascadeFreeString).
//
//export CascadeStatusJSON
func CascadeStatusJSON(handle C.longlong) *C.char {
	cs := lookup(int64(handle))
	if cs == nil {
		return C.CString("[]")
	}
	sts := cs.mgr.Statuses()
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
		return C.CString("[]")
	}
	return C.CString(string(data))
}

// CascadeClose stops a client's service loop and releases its handle.
//
//export CascadeClose
func CascadeClose(handle C.longlong) {
	regMu.Lock()
	cs := reg[int64(handle)]
	delete(reg, int64(handle))
	regMu.Unlock()
	if cs != nil {
		cs.cancel()
	}
}

// CascadeFreeString frees a string returned by this library.
//
//export CascadeFreeString
func CascadeFreeString(s *C.char) { C.free(unsafe.Pointer(s)) }

func main() {} // required for c-shared, never called
