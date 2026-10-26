//go:build !windows

package main

import (
	"os"
	"os/exec"
	"syscall"
)

// detach makes the launched app outlive this short-lived host process.
func detach(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true} // own session
}

// tryLock takes an exclusive advisory lock on path so concurrent hosts don't
// launch two apps. ok=false means another host holds it.
func tryLock(path string) (unlock func(), ok bool) {
	lf, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return func() {}, true // can't lock; proceed rather than block launching
	}
	if err := syscall.Flock(int(lf.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lf.Close()
		return func() {}, false
	}
	return func() {
		_ = syscall.Flock(int(lf.Fd()), syscall.LOCK_UN)
		lf.Close()
	}, true
}
