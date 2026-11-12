package paths

import (
	"strings"
	"testing"
)

func TestSafeName(t *testing.T) {
	cases := []struct{ in, want string }{
		{"file.bin", "file.bin"},
		{"../../evil.bin", "evil.bin"},
		{`..\..\evil.bin`, "evil.bin"},
		{`\..\..\Windows\evil.bin`, "evil.bin"},
		{"sub/dir/name.bin", "name.bin"},
		{"..", ""},
		{".", ""},
		{"/", ""},
		{"", ""},
		{"C:evil", "C_evil"},
		{`a*b?c"d<e>f|g.txt`, "a_b_c_d_e_f_g.txt"},
		{"a\x00b\x1fc.txt", "a_b_c.txt"},
		{"report.pdf. ", "report.pdf"},
		{"CON", ""},
		{"nul.txt", ""},
		{"con.tar.gz", ""},
		{"console.log", "console.log"},
		{strings.Repeat("a", 300) + ".tar.gz", strings.Repeat("a", 197) + ".gz"},
	}
	for _, c := range cases {
		if got := SafeName(c.in); got != c.want {
			t.Errorf("SafeName(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
