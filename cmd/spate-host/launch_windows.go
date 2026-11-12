//go:build windows

package main

import (
	"os"
	"os/exec"
	"syscall"
	"time"
)

const (
	detachedProcess  = 0x00000008 // DETACHED_PROCESS (no console, not a child console group)
	breakawayFromJob = 0x01000000 // CREATE_BREAKAWAY_FROM_JOB
)

// detach makes the launched app outlive this short-lived host process.
func detach(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP | detachedProcess,
		HideWindow:    true,
	}
}

// start runs the launch command and lets go of the child. Firefox puts a
// native host in a job object and ends the whole job when the host exits,
// which would take the freshly launched app down with it; the app therefore
// asks to leave the job. A job that forbids breakaway makes that launch fail
// with access denied, so the launch is retried inside the job (the behaviour
// before this flag was added) rather than not starting the app at all.
func start(cmd *exec.Cmd) error {
	out := exec.Command(cmd.Path, cmd.Args[1:]...)
	out.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP | detachedProcess | breakawayFromJob,
		HideWindow:    true,
	}
	if err := out.Start(); err == nil {
		return out.Process.Release()
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	return cmd.Process.Release()
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
