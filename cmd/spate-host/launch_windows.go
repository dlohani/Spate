//go:build windows

package main

import (
	"os"
	"os/exec"
	"syscall"
	"time"
)

const detachedProcess = 0x00000008 // DETACHED_PROCESS (no console, not a child console group)

// detach makes the launched app outlive this short-lived host process.
func detach(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP | detachedProcess,
		HideWindow:    true,
	}
}

// tryLock uses an exclusively-created lock file (no flock on Windows). A lock
// older than a minute is treated as stale from a crashed host and reclaimed.
func tryLock(path string) (unlock func(), ok bool) {
	for attempt := 0; attempt < 2; attempt++ {
		f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if err == nil {
			f.Close()
			return func() { _ = os.Remove(path) }, true
		}
		if fi, statErr := os.Stat(path); statErr == nil && time.Since(fi.ModTime()) > time.Minute {
			_ = os.Remove(path) // stale
			continue
		}
		return func() {}, false
	}
	return func() {}, false
}
