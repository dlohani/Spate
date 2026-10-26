//go:build darwin

package download

import (
	"os"
	"syscall"
)

// bypassCache tells the kernel not to keep this file's pages in the unified
// buffer cache. A download is written once and read back later, if at all,
// so caching gives nothing; worse, on macOS concurrent writes into a file of
// several GiB through the cache cost several kernel-CPU seconds per GiB and
// evict the user's working set. With F_NOCACHE the same writes cost a
// fraction and the cache is left alone. Measured on APFS, Apple M4: 4 GiB
// over 8 connections, 7.2 s kernel CPU with the cache vs 2.8 s without, at
// four times the throughput. Best effort: an error is ignored.
func bypassCache(f *os.File) {
	if os.Getenv("SPATE_PAGE_CACHE") == "1" {
		return // escape hatch: write through the cache as before
	}
	const fNOCACHE = 48 // F_NOCACHE from <fcntl.h>
	_, _, _ = syscall.Syscall(syscall.SYS_FCNTL, f.Fd(), fNOCACHE, 1)
}

// releaseCache is a no-op on macOS (nothing was cached).
func releaseCache(f *os.File) {}
