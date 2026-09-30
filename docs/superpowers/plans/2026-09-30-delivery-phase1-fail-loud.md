# Delivery Phase 1: Fail-Loud Packaging and CI Matrix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Windows build can no longer ship without the Flutter UI unless explicitly asked to, every packaging failure stops `./build` with a non-zero exit, releases require a clean tagged tree, and a CI matrix builds each platform on its own OS.

**Architecture:** The check "is the Flutter Windows bundle complete" is written once for shell (`scripts/lib/bundle.sh`) and once for Go (`internal/bundle`, used by the embedded payload of `cascade-setup.exe`), each with its own test. `scripts/build-windows.sh` and the `build` front door consume the shell check; `cmd/cascade-setup` consumes the Go one. A GitHub Actions workflow runs the existing `./build` targets on macOS, Windows and Ubuntu runners.

**Tech Stack:** bash 3.2 compatible shell, Go 1.22+ standard library, GitHub Actions, NSIS, Flutter 3.47 stable.

**Spec:** `docs/delivery.md`, section "Phase 1: build where it must be built, fail loud". Out of this plan and into the next: the per-OS installer smoke test, and the decision between the two Windows installers.

## Global Constraints

- Shell scripts stay bash 3.2 compatible (macOS default shell): no associative arrays, no `${var,,}`, no `mapfile`.
- Go code is standard library only; `go.mod` has no `require` block and must stay that way.
- `VERSION` is the single source of the version; scripts read it, never hardcode it.
- User-facing text: no emojis, no em-dashes.
- `dist/` is gitignored; tests must not depend on real build products and must use temporary directories.
- The `build` front door prints only lines beginning with `==>` from sub-scripts plus notes; errors must reach the terminal and set a non-zero exit.
- `CASCADE_ALLOW_NO_UI` enables the CLI-only Windows artifact only when set to exactly `1`.

## Review Focus

1. A `cascade_app` folder that exists but lacks `cascade_app.exe` (a half-copied bundle) must count as missing. Test in Task 1 and Task 4.
2. A bundle with the exe but without `cascade.dll` beside it would launch and fail at FFI load; it must count as missing. Test in Task 1 and Task 4.
3. `CASCADE_ALLOW_NO_UI=0`, `=true` or `=yes` must not enable the override. Test in Task 1.
4. `./build windows` when `scripts/build-windows.sh` fails must exit non-zero and must not print the artifacts summary. Verified by running it in Task 3.
5. `cascade-setup.exe --no-ui` on a machine with an older `bin\cascade_app` already installed keeps and launches that older UI. That is intended for development and is documented in Task 6; the setup prints the installed UI's location so the user sees it is not from this setup.

---

### Task 1: Shell bundle check with a test runner

**Files:**
- Create: `scripts/lib/bundle.sh`
- Create: `scripts/test/run.sh`
- Create: `scripts/test/bundle.test.sh`

**Interfaces:**
- Produces: `ui_bundle_ok DIR` (returns 0 when `DIR/cascade_app/cascade_app.exe` and `DIR/cascade_app/cascade.dll` both exist, 1 otherwise); `allow_no_ui` (returns 0 when `CASCADE_ALLOW_NO_UI` is exactly `1`, 1 otherwise); `ui_bundle_missing_message DIR` (prints the multi-line explanation to stdout).

- [ ] **Step 1: Write the test runner**

`scripts/test/run.sh`:

```bash
#!/usr/bin/env bash
# Runs every scripts/test/*.test.sh in its own shell; exit 1 if any fails.
#   scripts/test/run.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
for t in "$ROOT"/scripts/test/*.test.sh; do
  name="$(basename "$t" .test.sh)"
  if bash "$t"; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    fail=1
  fi
done
exit $fail
```

- [ ] **Step 2: Write the failing test**

`scripts/test/bundle.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for scripts/lib/bundle.sh. Each check prints "  not ok: <what>" on failure.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/lib/bundle.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
rc=0
check() { # DESCRIPTION EXPECTED_STATUS ACTUAL_STATUS
  if [ "$2" != "$3" ]; then echo "  not ok: $1 (want $2, got $3)"; rc=1; fi
}

# ui_bundle_ok
ui_bundle_ok "$TMP"; check "no cascade_app folder is missing" 1 $?
mkdir -p "$TMP/cascade_app"
ui_bundle_ok "$TMP"; check "empty cascade_app folder is missing" 1 $?
: > "$TMP/cascade_app/cascade_app.exe"
ui_bundle_ok "$TMP"; check "exe without cascade.dll is missing" 1 $?
: > "$TMP/cascade_app/cascade.dll"
ui_bundle_ok "$TMP"; check "exe and dll present is ok" 0 $?

# allow_no_ui
( unset CASCADE_ALLOW_NO_UI; allow_no_ui ); check "unset does not allow" 1 $?
( CASCADE_ALLOW_NO_UI=0 allow_no_ui );    check "0 does not allow" 1 $?
( CASCADE_ALLOW_NO_UI=true allow_no_ui ); check "true does not allow" 1 $?
( CASCADE_ALLOW_NO_UI=yes allow_no_ui );  check "yes does not allow" 1 $?
( CASCADE_ALLOW_NO_UI=1 allow_no_ui );    check "1 allows" 0 $?

# message names the folder and the override
msg="$(ui_bundle_missing_message "$TMP")"
case "$msg" in *"$TMP/cascade_app"*) ;; *) echo "  not ok: message names the folder"; rc=1 ;; esac
case "$msg" in *CASCADE_ALLOW_NO_UI=1*) ;; *) echo "  not ok: message names the override"; rc=1 ;; esac
case "$msg" in *flutter-windows.ps1*) ;; *) echo "  not ok: message names the build script"; rc=1 ;; esac
exit $rc
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `chmod +x scripts/test/run.sh && scripts/test/run.sh`
Expected: `FAIL bundle` with a "No such file or directory" error for `scripts/lib/bundle.sh`, exit 1.

- [ ] **Step 4: Write the library**

`scripts/lib/bundle.sh`:

```bash
# Shared by the Windows build and packaging scripts: is the Flutter Windows
# bundle present and complete, and did the caller explicitly allow a build
# without it? Source it; bash 3.2 compatible.

# ui_bundle_ok DIR: 0 when DIR/cascade_app holds the app exe and the core DLL
# the Dart loader needs beside it; 1 otherwise (a half-copied folder counts
# as missing).
ui_bundle_ok() {
  [ -f "$1/cascade_app/cascade_app.exe" ] && [ -f "$1/cascade_app/cascade.dll" ]
}

# allow_no_ui: 0 only when CASCADE_ALLOW_NO_UI is exactly "1".
allow_no_ui() {
  [ "${CASCADE_ALLOW_NO_UI:-}" = "1" ]
}

# ui_bundle_missing_message DIR: what to print when the bundle is missing.
ui_bundle_missing_message() {
  cat <<MSG
error: the Flutter Windows UI is not at $1/cascade_app (needs cascade_app.exe and cascade.dll).
  Build it on Windows:  powershell -ExecutionPolicy Bypass -File scripts\\flutter-windows.ps1 -CopyTo <this checkout>
  then run this build again. For a CLI-only artifact without the UI, set CASCADE_ALLOW_NO_UI=1.
MSG
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `scripts/test/run.sh`
Expected: `ok   bundle`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/bundle.sh scripts/test/run.sh scripts/test/bundle.test.sh
git commit -m "build: shell check for the Flutter Windows bundle, with a script test runner"
```

---

### Task 2: `scripts/build-windows.sh` refuses to package without the UI

**Files:**
- Modify: `scripts/build-windows.sh`

**Interfaces:**
- Consumes: `ui_bundle_ok`, `allow_no_ui`, `ui_bundle_missing_message` from Task 1.
- Produces: exit 1 with the message when the bundle is missing and the override is unset; with `CASCADE_ALLOW_NO_UI=1` the zip is `dist/cascade-windows-amd64-cli-only.zip` instead of `dist/cascade-windows-amd64.zip`. `CC` is taken from the environment when set (so a Windows runner can pass `CC=gcc`). When `zip` is absent, `7z a -tzip` is used.

- [ ] **Step 1: Replace the compiler line and add the guard**

In `scripts/build-windows.sh`, replace

```bash
CC=x86_64-w64-mingw32-gcc
command -v "$CC" >/dev/null || { echo "missing $CC: brew install mingw-w64"; exit 1; }
```

with

```bash
. "$ROOT/scripts/lib/bundle.sh"
CC="${CC:-x86_64-w64-mingw32-gcc}"
command -v "$CC" >/dev/null || { echo "missing $CC: brew install mingw-w64 (or set CC)"; exit 1; }
```

Then replace the payload block

```bash
if [ -d "$OUT/cascade_app" ]; then
  cp -R "$OUT/cascade_app" "$PAY/bin/cascade_app"
else
  echo "    note: no Flutter Windows bundle at $OUT/cascade_app; build it on Windows (scripts/flutter-windows.ps1) and copy it there for a setup with the UI"
fi
```

with

```bash
ZIP="cascade-windows-amd64.zip"
if ui_bundle_ok "$OUT"; then
  cp -R "$OUT/cascade_app" "$PAY/bin/cascade_app"
elif allow_no_ui; then
  echo "==> CLI-only build: no Flutter Windows UI (CASCADE_ALLOW_NO_UI=1)"
  ZIP="cascade-windows-amd64-cli-only.zip"
else
  ui_bundle_missing_message "$OUT" >&2
  exit 1
fi
```

- [ ] **Step 2: Use the zip name and add the 7z fallback**

Replace

```bash
(cd "$ROOT/dist" && rm -f cascade-windows-amd64.zip && zip -qr cascade-windows-amd64.zip windows-amd64)
ls -la "$OUT" "$ROOT/dist/cascade-windows-amd64.zip"
```

with

```bash
(cd "$ROOT/dist" && rm -f cascade-windows-amd64.zip cascade-windows-amd64-cli-only.zip &&
  if command -v zip >/dev/null; then zip -qr "$ZIP" windows-amd64; else 7z a -tzip -bso0 "$ZIP" windows-amd64; fi)
ls -la "$OUT" "$ROOT/dist/$ZIP"
```

- [ ] **Step 3: Verify the guard fires**

Run: `rm -rf dist/windows-amd64/cascade_app; scripts/build-windows.sh; echo "exit $?"`
Expected: the three `==>` build lines, then the `error: the Flutter Windows UI is not at .../dist/windows-amd64/cascade_app` message, then `exit 1`. No `cascade-setup.exe` line and no zip.

- [ ] **Step 4: Verify the override**

Run: `CASCADE_ALLOW_NO_UI=1 scripts/build-windows.sh | tail -3; ls dist/*.zip`
Expected: `==> CLI-only build: no Flutter Windows UI (CASCADE_ALLOW_NO_UI=1)` in the output and `dist/cascade-windows-amd64-cli-only.zip` listed.

- [ ] **Step 5: Verify a fake complete bundle passes**

Run:
```bash
mkdir -p dist/windows-amd64/cascade_app && : > dist/windows-amd64/cascade_app/cascade_app.exe && : > dist/windows-amd64/cascade_app/cascade.dll
scripts/build-windows.sh | tail -2; ls dist/*.zip; rm -rf dist/windows-amd64/cascade_app
```
Expected: no error, `dist/cascade-windows-amd64.zip` listed. (The two empty files are only a stand-in for the bundle; they are removed at the end.)

- [ ] **Step 6: Commit**

```bash
git add scripts/build-windows.sh
git commit -m "build-windows.sh: refuse to package without the Flutter UI; CLI-only zip only with CASCADE_ALLOW_NO_UI=1"
```

---

### Task 3: The `build` front door surfaces failures and both zip names

**Files:**
- Modify: `build` (function `do_windows`)

**Interfaces:**
- Consumes: the exit status and the two possible zip names from Task 2.
- Produces: `./build windows` exits 1 when `scripts/build-windows.sh` fails, printing the script's error lines; the artifacts summary is not printed on failure.

- [ ] **Step 1: Rewrite `do_windows`**

Replace the current function

```bash
do_windows() {
  say "Windows $LABEL"
  need x86_64-w64-mingw32-gcc "brew install mingw-w64" || return 0
  scripts/build-windows.sh | grep -E "^==>" || true
  if [ -f "$DIST/cascade-windows-amd64.zip" ]; then
    mv -f "$DIST/cascade-windows-amd64.zip" "$DIST/cascade-windows-amd64-$VERSION.zip"; label "$DIST/cascade-windows-amd64-$VERSION.zip" windows
  fi
```

with

```bash
do_windows() {
  say "Windows $LABEL"
  need "${CC:-x86_64-w64-mingw32-gcc}" "brew install mingw-w64" || return 0
  # Show the script's progress lines and every error line, and keep its exit
  # status: the grep is wrapped so "no match" cannot fail the pipeline, and
  # with pipefail the pipeline's status is then the script's own.
  local status=0
  scripts/build-windows.sh 2>&1 | { grep -E "^==>|^error|^  " || true; } || status=$?
  if [ "$status" != 0 ]; then
    echo "==> Windows build failed (see above)" >&2
    exit 1
  fi
  for z in cascade-windows-amd64.zip cascade-windows-amd64-cli-only.zip; do
    if [ -f "$DIST/$z" ]; then
      mv -f "$DIST/$z" "$DIST/${z%.zip}-$VERSION.zip"; label "$DIST/${z%.zip}-$VERSION.zip" windows
    fi
  done
```

Keep the rest of the function (the `makensis` branch) unchanged, but replace its inner check

```bash
    if [ -d "$DIST/windows-amd64/cascade_app" ]; then
```

with

```bash
    if ui_bundle_ok "$DIST/windows-amd64"; then
```

and add, directly after the `DIST="$ROOT/dist"` line near the top of `build`:

```bash
. "$ROOT/scripts/lib/bundle.sh"
```

- [ ] **Step 2: Verify the failure path**

Run: `rm -rf dist/windows-amd64/cascade_app; ./build windows --no-test; echo "exit $?"`
Expected: the `==> Windows 0.4.0+...` banner, the three `==>` build lines, the indented `error:` message from the bundle check, `==> Windows build failed (see above)`, `exit 1`, and no `==> artifacts` block.

- [ ] **Step 3: Verify the override path**

Run: `CASCADE_ALLOW_NO_UI=1 ./build windows --no-test; echo "exit $?"; ls dist/windows/`
Expected: `exit 0`, and `dist/windows/` holds `cascade-windows-amd64-cli-only-0.4.0+<sha>.dirty.zip` and its `.sha256`. Remove any older `cascade-windows-amd64-0.4.0+...zip` left from before this change so the folder is not misleading.

- [ ] **Step 4: Run the script tests**

Run: `scripts/test/run.sh`
Expected: `ok   bundle`.

- [ ] **Step 5: Commit**

```bash
git add build
git commit -m "build: Windows failures stop the front door; CLI-only zips are labelled as such"
```

---

### Task 4: `cascade-setup.exe` refuses to install without the UI in its payload

**Files:**
- Create: `internal/bundle/bundle.go`
- Create: `internal/bundle/bundle_test.go`
- Modify: `cmd/cascade-setup/main.go:57-63` (flags) and `cmd/cascade-setup/main.go:132-135` (UI check)

**Interfaces:**
- Produces: `bundle.HasWindowsUI(fsys fs.FS, root string) bool` in package `cascade/internal/bundle`. Returns true when `root + "/bin/cascade_app/cascade_app.exe"` and `root + "/bin/cascade_app/cascade.dll"` are regular files in `fsys`. `root` uses forward slashes, as `embed.FS` does.
- Produces: a `--no-ui` flag on `cascade-setup.exe`.

- [ ] **Step 1: Write the failing test**

`internal/bundle/bundle_test.go`:

```go
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `go test ./internal/bundle/`
Expected: compile error, `undefined: HasWindowsUI` (or "no Go files" until the package file exists).

- [ ] **Step 3: Write the package**

`internal/bundle/bundle.go`:

```go
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `go test ./internal/bundle/ -v`
Expected: both tests `PASS`.

- [ ] **Step 5: Wire it into the setup**

In `cmd/cascade-setup/main.go`, add to the imports:

```go
	"cascade/internal/bundle"
```

Add a flag after the `force` flag:

```go
	noUI := flag.Bool("no-ui", false, "install the command-line pieces even though this setup carries no Flutter UI (development only)")
```

Directly after `fmt.Println("Cascade setup", version.Version)`, before the installed-version switch, add:

```go
	if !bundle.HasWindowsUI(payload, "payload") && !*noUI {
		fmt.Println("  This setup was packaged without the Flutter UI (bin\\cascade_app), so it")
		fmt.Println("  would install a Cascade you cannot open. Build the UI on Windows with")
		fmt.Println("  scripts\\flutter-windows.ps1 -CopyTo <checkout>, then ./build windows on the Mac.")
		fmt.Println("  To install only the command-line pieces anyway, run with --no-ui.")
		pause()
		os.Exit(1)
	}
```

Replace the existing block

```go
	app := filepath.Join(bin, "cascade_app", "cascade_app.exe")
	if _, err := os.Stat(app); err != nil {
		fmt.Println("  ! the Flutter UI (bin\\cascade_app) is not in this setup; build it with scripts\\flutter-windows.ps1")
	}
```

with

```go
	app := filepath.Join(bin, "cascade_app", "cascade_app.exe")
	if _, err := os.Stat(app); err != nil {
		fmt.Println("  ! no Flutter UI installed (--no-ui): the app will not start until bin\\cascade_app is built and copied in")
	} else if *noUI {
		fmt.Println("  ! --no-ui: keeping the previously installed UI at", app, "(not from this setup)")
	}
```

Update the doc comment at the top of the file: add the line

```go
//	cascade-setup.exe --no-ui              install without the Flutter UI (development only)
```

after the `--force` line.

- [ ] **Step 6: Build for Windows and run the whole suite**

Run: `GOOS=windows GOARCH=amd64 go build -o /dev/null ./cmd/cascade-setup && go vet ./... && go test ./...`
Expected: the cross-build succeeds (the payload directory must exist; run `CASCADE_ALLOW_NO_UI=1 scripts/build-windows.sh` first if `cmd/cascade-setup/payload` is absent), vet is silent, all tests pass.

- [ ] **Step 7: Commit**

```bash
git add internal/bundle cmd/cascade-setup/main.go
git commit -m "cascade-setup: refuse to install without the Flutter UI unless --no-ui"
```

---

### Task 5: Release gate in the `build` front door

**Files:**
- Modify: `build` (argument parsing and the target loop)

**Interfaces:**
- Produces: `./build release <target...>`. Refuses with exit 2 when the tree is dirty or HEAD is not exactly on a tag; otherwise runs the given targets with `LABEL` equal to `VERSION`. Also refuses when `CASCADE_ALLOW_NO_UI` is set, so a release can never be CLI-only.

- [ ] **Step 1: Add the gate**

In `build`, add after the `BUILDNUM=` line:

```bash
# require_release: a release-labelled build needs a clean tree on a tag and
# must carry the UI.
require_release() {
  local why=""
  [ -z "$DIRTY" ] || why="uncommitted changes"
  [ -n "$TAGGED" ] || why="${why:+$why, }HEAD is not on a tag"
  [ -z "${CASCADE_ALLOW_NO_UI:-}" ] || why="${why:+$why, }CASCADE_ALLOW_NO_UI is set"
  if [ -n "$why" ]; then
    echo "release: refused ($why). Commit, tag v$VERSION, unset overrides, then retry." >&2
    exit 2
  fi
}
```

In the argument loop, `release` must be recognised before the targets. Replace

```bash
[ ${#TARGETS[@]} -gt 0 ] || { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
```

with

```bash
[ ${#TARGETS[@]} -gt 0 ] || { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
if [ "${TARGETS[0]}" = release ]; then
  require_release
  # (check the count before slicing: an empty array trips bash 3.2 + set -u)
  [ ${#TARGETS[@]} -gt 1 ] || { echo "release: name at least one target (e.g. ./build release all)" >&2; exit 2; }
  TARGETS=("${TARGETS[@]:1}")
fi
```

Add to the header comment (the usage text printed by `--help`), after the `./build all` line:

```bash
#   ./build release <target...>      same, but refuses unless the tree is clean and HEAD is tagged
```

- [ ] **Step 2: Ignore the local tool folder**

`git status --porcelain` currently lists the untracked `.serena/` folder (an editor tool's cache), which is why every build so far carried the `.dirty` label and which would make the gate refuse forever. Add to `.gitignore`, under "# OS cruft":

```
# editor / assistant tool caches
.serena/
```

Run: `git status --porcelain`
Expected: no `?? .serena/` line.

- [ ] **Step 3: Verify the refusal**

Run: `./build release windows; echo "exit $?"`
Expected: `release: refused (HEAD is not on a tag). Commit, tag v0.4.0, unset overrides, then retry.` and `exit 2`. (If the tree has uncommitted changes the reason lists both.)

- [ ] **Step 4: Verify the pass-through on a tagged clean tree**

Run:
```bash
git tag -f v0.4.0-plan-check && ./build release version; echo "exit $?"; git tag -d v0.4.0-plan-check
```
Expected: `version 0.4.0  label 0.4.0  build <n>  (<sha>)` and `exit 0`. The temporary tag is deleted afterwards. If the tree is dirty at this point, commit the previous tasks first; the check is meant to refuse dirty trees.

- [ ] **Step 5: Commit**

```bash
git add build .gitignore
git commit -m "build: release gate refuses dirty, untagged or CLI-only builds"
```

---

### Task 6: Documentation

**Files:**
- Modify: `README.md` (the "Build" section)
- Modify: `docs/vm-testing.md` (the "Windows (VM), quickest" and "building the Flutter UI" sections)

- [ ] **Step 1: README build section**

After the paragraph that ends "Missing toolchains (mingw, makensis, Android SDK, gomobile) are reported in one line and that piece is skipped.", add:

```markdown
Two things are never skipped silently. A Windows build without the Flutter
UI at `dist/windows-amd64/cascade_app` fails; set `CASCADE_ALLOW_NO_UI=1`
for a CLI-only artifact, which is then named `...-cli-only.zip` and whose
setup refuses to install unless run with `--no-ui`. And `./build release
<target...>` refuses unless the tree is clean and HEAD is on a tag, so a
release-labelled artifact always comes from a known commit. Script tests:
`scripts/test/run.sh`.
```

- [ ] **Step 2: vm-testing.md**

In "Windows (VM), quickest: the installer", replace the last sentence "The installer needs the Flutter UI, which is built on Windows (below): copy its Release folder to `dist\windows-amd64\cascade_app` on the Mac, then package." with:

```markdown
The installer needs the Flutter UI, which is built on Windows (below).
`./build windows` refuses to package without it, and a setup built with
`CASCADE_ALLOW_NO_UI=1` refuses to install without `--no-ui`, so a build
missing the UI cannot be mistaken for a complete one.
```

- [ ] **Step 3: Commit**

```bash
git add README.md docs/vm-testing.md
git commit -m "docs: fail-loud Windows packaging and the release gate"
```

---

### Task 7: GitHub Actions matrix

This task cannot be verified on the developer Mac: the repository has no remote yet. The workflow is written to the existing scripts' contracts; the first push runs it, and the task is complete only when all three jobs are green.

**Files:**
- Create: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: `./build mac`, `./build linux`, `./build windows`, `scripts/flutter-windows.ps1`, `CC` override from Task 2, `scripts/test/run.sh` from Task 1.

- [ ] **Step 1: Write the workflow**

`.github/workflows/build.yml`:

```yaml
name: build
on:
  push:
    branches: [main]
    tags: ["v*"]
  pull_request:

env:
  GO_VERSION: "1.27.x"
  FLUTTER_VERSION: "3.47.5"

jobs:
  test:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with: { go-version: "${{ env.GO_VERSION }}" }
      - run: go vet ./...
      - run: go test -race ./...
      - run: scripts/test/run.sh
      - name: core stays standard-library only
        run: |
          if grep -q '^require' go.mod; then echo "go.mod has a require block; the core must stay standard-library only" >&2; exit 1; fi

  macos:
    needs: test
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: actions/setup-go@v5
        with: { go-version: "${{ env.GO_VERSION }}" }
      - uses: subosito/flutter-action@v2
        with: { channel: stable, flutter-version: "${{ env.FLUTTER_VERSION }}" }
      - run: ./build mac extension --no-test
      - uses: actions/upload-artifact@v4
        with:
          name: macos
          path: |
            dist/macos/*
            dist/extension/*

  linux:
    needs: test
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: actions/setup-go@v5
        with: { go-version: "${{ env.GO_VERSION }}" }
      - uses: subosito/flutter-action@v2
        with: { channel: stable, flutter-version: "${{ env.FLUTTER_VERSION }}" }
      - run: |
          sudo apt-get update
          sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev libayatana-appindicator3-dev
      - run: ./build linux --no-test
      - uses: actions/upload-artifact@v4
        with: { name: linux, path: "dist/linux/*" }

  windows:
    needs: test
    runs-on: windows-2022
    defaults:
      run: { shell: bash }
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: actions/setup-go@v5
        with: { go-version: "${{ env.GO_VERSION }}" }
      - uses: subosito/flutter-action@v2
        with: { channel: stable, flutter-version: "${{ env.FLUTTER_VERSION }}" }
      - name: toolchain (MinGW for the DLL, NSIS for the installer)
        run: choco install mingw nsis -y --no-progress
      - name: toolchain check
        # A step's PATH is fixed at job start; if either command is missing
        # after the install above, append the install folder to $GITHUB_PATH
        # in the previous step (choco prints where it installed) and re-run.
        run: |
          gcc --version | head -1
          makensis -VERSION
          7z | head -2
      - name: Flutter Windows UI (builds cascade.dll natively when absent)
        shell: pwsh
        run: powershell -ExecutionPolicy Bypass -File scripts\flutter-windows.ps1 -CopyTo (Get-Location).Path
      - name: package
        env: { CC: gcc }
        run: ./build windows --no-test
      - uses: actions/upload-artifact@v4
        with: { name: windows, path: "dist/windows/*" }
```

- [ ] **Step 2: Check the YAML parses and the referenced scripts exist**

Run: `ruby -ryaml -e 'YAML.load_file(".github/workflows/build.yml"); puts "yaml ok"' && ls scripts/flutter-windows.ps1 scripts/test/run.sh build`
Expected: `yaml ok` and the three paths listed.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: build matrix on macOS, Windows and Ubuntu runners"
```

- [ ] **Step 4: Push and watch (needs a remote)**

Run: `git remote -v` first. If empty, create the GitHub repository, add it as `origin`, then `git push -u origin main`. Watch the run with `gh run watch`. If a job fails on a missing tool or path, fix it inside this task and push again; the task is done when `test`, `macos`, `linux` and `windows` are all green and each uploads its artifact.

Expected end state: three artifacts downloadable from the run, the Windows one holding `Cascade-Setup-0.4.0+<sha>.exe` (the NSIS installer is produced because the runner built the UI) and `cascade-windows-amd64-0.4.0+<sha>.zip`.

---

## Self-review notes

- Spec coverage: Phase 1 bullets 1 (CI), 2 (build refuses), 3 (setup refuses), 4 (release gate) are Tasks 7, 2+3, 4, 5. Bullet 5 (smoke test) and bullet 6 (which installer stays) are explicitly deferred to the next plan.
- Names used across tasks: `ui_bundle_ok`, `allow_no_ui`, `ui_bundle_missing_message` (Task 1, used in 2 and 3); `bundle.HasWindowsUI` (Task 4); zip names `cascade-windows-amd64.zip` and `cascade-windows-amd64-cli-only.zip` (Task 2, used in 3); `CC` override (Task 2, used in 7).
- Review Focus items 1 and 2 are pinned by tests in Task 1 and Task 4; item 3 by Task 1; item 4 by the run in Task 3 Step 2; item 5 by the message in Task 4 Step 5 and the docs in Task 6.
