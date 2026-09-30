package bundle

import (
	"testing"
	"testing/fstest"
)

func TestHasWindowsUI(t *testing.T) {
	exe := "payload/bin/cascade_app/cascade_app.exe"
	dll := "payload/bin/cascade_app/cascade.dll"
	cases := []struct {
		name  string
		files []string
		want  bool
	}{
		{"nothing", nil, false},
		{"folder only", []string{"payload/bin/cascade_app/.keep"}, false},
		{"exe without dll", []string{exe}, false},
		{"dll without exe", []string{dll}, false},
		{"exe and dll", []string{exe, dll}, true},
	}
	for _, c := range cases {
		fsys := fstest.MapFS{}
		for _, f := range c.files {
			fsys[f] = &fstest.MapFile{Data: []byte("x")}
		}
		if got := HasWindowsUI(fsys, "payload"); got != c.want {
			t.Errorf("%s: HasWindowsUI = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestHasWindowsUIRejectsDirectoryNamedLikeTheExe(t *testing.T) {
	fsys := fstest.MapFS{
		"payload/bin/cascade_app/cascade_app.exe/inner": &fstest.MapFile{Data: []byte("x")},
		"payload/bin/cascade_app/cascade.dll":           &fstest.MapFile{Data: []byte("x")},
	}
	if HasWindowsUI(fsys, "payload") {
		t.Error("a directory named cascade_app.exe must not count as the app")
	}
}
