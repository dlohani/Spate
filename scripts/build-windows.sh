#!/usr/bin/env bash
# Cross-compile the Windows (amd64) binaries from macOS/Linux and package them:
#   cascade.exe        CLI (pure Go)
#   cascade-host.exe   browser native-messaging host (pure Go)
#   cascade.dll/.h     the core as a C shared library (needs mingw-w64)
# The Flutter Windows UI must be built on Windows (scripts/flutter-windows.ps1)
# and copied to dist/windows-amd64/cascade_app; the build refuses without it.
# CASCADE_ALLOW_NO_UI=1 produces a CLI-only artifact instead, whose
# cascade-setup.exe then needs --no-ui to install.
#
#   brew install mingw-w64   (once)
#   scripts/build-windows.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/go/bin:/opt/homebrew/bin:/usr/local/go/bin:$PATH"
OUT="$ROOT/dist/windows-amd64"
. "$ROOT/scripts/lib/bundle.sh"
. "$ROOT/scripts/lib/obfuscate.sh"
export OBF_ROOT="$ROOT"
CC="${CC:-x86_64-w64-mingw32-gcc}"
command -v "$CC" >/dev/null || { echo "missing $CC: brew install mingw-w64 (or set CC)" >&2; exit 1; }
mkdir -p "$OUT"
find "$OUT" -maxdepth 1 -type f -delete   # keep dist/windows-amd64/cascade_app (built on Windows)
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
LD="-s -w -X cascade/internal/version.Version=$VERSION"
obf_require_garble   # CASCADE_OBFUSCATE=1 without garble fails loud, never ships plain

echo "==> cascade.exe (CLI)"
cmd="$(go_build_cmd cli)"
# shellcheck disable=SC2086
(cd "$ROOT" && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 $cmd -ldflags "$LD" -o "$OUT/cascade.exe" ./cmd/cascade)
echo "==> cascade-host.exe (native messaging host)"
cmd="$(go_build_cmd cli)"
# shellcheck disable=SC2086
(cd "$ROOT" && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 $cmd -ldflags "$LD" -o "$OUT/cascade-host.exe" ./cmd/cascade-host)
echo "==> cascade.dll (core, C ABI)"
# Export only the Cascade* C ABI: mingw ld takes a .def as a linker input.
DEF="$(mktemp "${TMPDIR:-/tmp}/cascade-exports.XXXXXX")"; mv "$DEF" "$DEF.def"; DEF="$DEF.def"
trap 'rm -f "$DEF"' EXIT
"$ROOT/scripts/export-symbols.sh" def > "$DEF"
cmd="$(go_build_cmd lib)"
# The .def is handed to the external linker. On native Windows (Git Bash) the
# linker is a native binary that cannot resolve a POSIX /tmp path, so give it a
# Windows path; cygpath is absent on the macOS/Linux cross-build, where $DEF is
# already native.
DEF_LD="$DEF"; command -v cygpath >/dev/null 2>&1 && DEF_LD="$(cygpath -m "$DEF")"
# shellcheck disable=SC2086
(cd "$ROOT" && GOOS=windows GOARCH=amd64 CGO_ENABLED=1 CC="$CC" $cmd -ldflags "$LD -extldflags=$DEF_LD" -buildmode=c-shared -o "$OUT/cascade.dll" ./export/cshared)

echo "==> cascade-setup.exe (single-file installer embedding the binaries + extension)"
PAY="$ROOT/cmd/cascade-setup/payload"
rm -rf "$PAY" && mkdir -p "$PAY/bin" "$PAY/extension"
cp "$OUT/cascade-host.exe" "$OUT/cascade.exe" "$OUT/cascade.dll" "$ROOT/browser/extension/store-ids.env" "$PAY/bin/"
ZIP="cascade-windows-amd64.zip"
if ui_bundle_ok "$OUT"; then
  cp "$OUT/cascade.dll" "$OUT/cascade_app/cascade.dll"   # the bundle carries the core this build just stamped
  cp -R "$OUT/cascade_app" "$PAY/bin/cascade_app"
elif allow_no_ui; then
  echo "==> CLI-only build: no Flutter Windows UI (CASCADE_ALLOW_NO_UI=1)"
  ZIP="cascade-windows-amd64-cli-only.zip"
else
  ui_bundle_missing_message "$OUT" >&2
  exit 1
fi
cp -R "$ROOT/browser/extension/." "$PAY/extension/"
cmd="$(go_build_cmd cli)"
# shellcheck disable=SC2086
(cd "$ROOT" && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 $cmd -ldflags "$LD" -o "$OUT/cascade-setup.exe" ./cmd/cascade-setup)

echo "==> packaging"
cp -R "$ROOT/browser/extension" "$OUT/extension"
cp "$ROOT/scripts/install-windows.ps1" "$ROOT/scripts/flutter-windows.ps1" "$OUT/"
cat > "$OUT/README-windows.txt" <<'TXT'
Cascade for Windows (amd64) -- dev build

Quick start: double-click cascade-setup.exe. It installs to
%LOCALAPPDATA%\Cascade, registers the browser native host (Chrome, Chromium,
Edge, Brave), adds a hidden autostart, and launches the app. Then load the
extension it extracted (chrome://extensions -> Developer mode -> Load unpacked
-> %LOCALAPPDATA%\Cascade\extension). If the extension's Options page shows a
different ID than setup printed, run: cascade-setup.exe --extension-id <ID>
Windows SmartScreen will warn: the binaries are unsigned.

  cascade-setup.exe --uninstall   removes it again

Running setup again reinstalls the same version or upgrades an older one
(settings and downloads are kept); an older setup than the installed version
is refused (--force overrides).

Manual alternative: install-windows.ps1 (same steps via PowerShell).
cascade.exe is the command-line downloader. cascade.dll is the core for the
Flutter UI, which you build on Windows with flutter-windows.ps1; the build
refuses to package without it. A CLI-only build (CASCADE_ALLOW_NO_UI=1)
has no cascade_app\, and its cascade-setup.exe needs --no-ui to install.
TXT
(cd "$ROOT/dist" && rm -f cascade-windows-amd64.zip cascade-windows-amd64-cli-only.zip &&
  if command -v zip >/dev/null; then zip -qr "$ZIP" windows-amd64; else 7z a -tzip -bso0 "$ZIP" windows-amd64; fi)
ls -la "$OUT" "$ROOT/dist/$ZIP"
