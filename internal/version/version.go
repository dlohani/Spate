// Package version holds the build version (from the VERSION file, injected at
// build time) and a comparison used by installers to refuse downgrades.
package version

import (
	"strconv"
	"strings"
)

// Version is set by the build: -ldflags "-X cascade/internal/version.Version=1.2.3".
// A plain `go build` reports a dev build.
var Version = "0.0.0-dev"

// Compare orders two dotted versions numerically ("0.10.0" > "0.9.1"). A
// pre-release or build suffix ("1.2.0-rc1", "1.2.0+7") is ignored, and
// missing components count as zero, so "1.2" == "1.2.0". Non-numeric
// components compare as text. Returns -1, 0 or 1.
func Compare(a, b string) int {
	as, bs := parts(a), parts(b)
	for len(as) < len(bs) {
		as = append(as, "0")
	}
	for len(bs) < len(as) {
		bs = append(bs, "0")
	}
	for i := range as {
		x, xErr := strconv.Atoi(as[i])
		y, yErr := strconv.Atoi(bs[i])
		switch {
		case xErr == nil && yErr == nil:
			if x != y {
				if x < y {
					return -1
				}
				return 1
			}
		default:
			if c := strings.Compare(as[i], bs[i]); c != 0 {
				return c
			}
		}
	}
	return 0
}

func parts(v string) []string {
	v = strings.TrimSpace(strings.TrimPrefix(v, "v"))
	if i := strings.IndexAny(v, "-+"); i >= 0 {
		v = v[:i]
	}
	if v == "" {
		return []string{"0"}
	}
	return strings.Split(v, ".")
}
