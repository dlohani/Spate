package version

import "testing"

func TestCompare(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"0.3.0", "0.4.0", -1},
		{"0.4.0", "0.3.0", 1},
		{"0.10.0", "0.9.1", 1},
		{"1.2", "1.2.0", 0},
		{"v1.2.0", "1.2.0", 0},
		{"1.2.0-rc1", "1.2.0", 0},
		{"1.2.0+7", "1.2.0", 0},
		{"", "0.0.0", 0},
		{"0.0.0-dev", "0.4.0", -1},
	}
	for _, c := range cases {
		if got := Compare(c.a, c.b); got != c.want {
			t.Errorf("Compare(%q,%q) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}
