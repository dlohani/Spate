//go:build !darwin && !linux

package download

import "os"

func bypassCache(f *os.File)  {}
func releaseCache(f *os.File) {}
