// Package bundle answers one question for the Windows installers: does this
// payload carry a complete Flutter UI? "Complete" means the app executable and
// the Go core DLL the Dart loader expects beside it. A folder with only one of
// them would install and then fail at first launch, so it counts as missing.
package bundle

import (
	"io/fs"
	"path"
)

// HasWindowsUI reports whether fsys holds root/bin/cascade_app/cascade_app.exe
// and root/bin/cascade_app/cascade.dll as regular files. root is slash
// separated, as embed.FS paths are.
func HasWindowsUI(fsys fs.FS, root string) bool {
	dir := path.Join(root, "bin", "cascade_app")
	return isFile(fsys, path.Join(dir, "cascade_app.exe")) && isFile(fsys, path.Join(dir, "cascade.dll"))
}

func isFile(fsys fs.FS, p string) bool {
	st, err := fs.Stat(fsys, p)
	return err == nil && st.Mode().IsRegular()
}
