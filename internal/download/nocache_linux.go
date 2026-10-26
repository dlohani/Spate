//go:build linux

package download

import (
	"os"
	"syscall"
)

// bypassCache is a no-op on Linux: there is no per-descriptor equivalent of
// F_NOCACHE short of O_DIRECT, whose alignment rules the segmented writer
// cannot meet. Instead releaseCache drops the pages after the data is
// flushed, so a multi-GiB download does not evict the user's working set.
func bypassCache(f *os.File) {}

// releaseCache asks the kernel to drop this file's cached pages
// (posix_fadvise POSIX_FADV_DONTNEED over the whole file). Best effort.
func releaseCache(f *os.File) {
	const posixFadvDontneed = 4
	_, _, _ = syscall.Syscall6(syscall.SYS_FADVISE64, f.Fd(), 0, 0, posixFadvDontneed, 0, 0)
}
