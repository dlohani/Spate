package paths

import (
	"path"
	"strings"
	"unicode/utf8"
)

// maxName leaves room for ".part" and " (N)" under the 255-byte limit.
const maxName = 200

// SafeName reduces an untrusted file name (from a browser, a server header or
// a URL path) to a single path element that is safe on every platform, so a
// name can only ever land inside the folder it is joined to. Both separator
// styles are honoured, characters Windows forbids (including ":" which is a
// drive and NTFS stream separator) become "_", trailing dots and spaces
// (which Win32 strips, aliasing names) are trimmed, Windows reserved device
// names are rejected, and over-long names are cut keeping the extension.
// "..", "." and empty collapse to "" so the caller falls back to a default.
func SafeName(name string) string {
	name = strings.ReplaceAll(name, "\\", "/")
	name = path.Base(path.Clean("/" + name))
	name = strings.Map(func(r rune) rune {
		switch {
		case r < 0x20, r == 0x7f:
			return '_'
		case strings.ContainsRune(`:*?"<>|`, r):
			return '_'
		}
		return r
	}, name)
	name = strings.TrimRight(name, ". ")
	switch name {
	case "/", ".", "..", "":
		return ""
	}
	// Windows resolves "CON.tar.gz" to the device too: test the part before
	// the first dot, not just the name minus its last extension.
	stem := name
	if i := strings.IndexByte(stem, '.'); i >= 0 {
		stem = stem[:i]
	}
	switch strings.ToUpper(strings.TrimRight(stem, " ")) {
	case "CON", "PRN", "AUX", "NUL",
		"COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
		"LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9":
		return ""
	}
	if len(name) > maxName {
		ext := path.Ext(name)
		if len(ext) > 20 {
			ext = ""
		}
		cut := maxName - len(ext)
		for cut > 0 && !utf8.RuneStart(name[cut]) {
			cut--
		}
		name = name[:cut] + ext
	}
	return name
}
