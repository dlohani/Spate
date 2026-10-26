#!/usr/bin/env bash
# Cross-compile the Windows (amd64) binaries from macOS/Linux and package them:
#   spate.exe        CLI (pure Go)
#   spate-host.exe   browser native-messaging host (pure Go)
#   spate.dll/.h     the core as a C shared library (needs mingw-w64)
# The Flutter Windows UI must be built on Windows (scripts/flutter-windows.ps1)
# and copied to dist/windows-amd64/spate_app; the build refuses without it.
# SPATE_ALLOW_NO_UI=1 produces a CLI-only artifact instead, whose
# spate-setup.exe then needs --no-ui to install.
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
find "$OUT" -maxdepth 1 -type f -delete   # keep dist/windows-amd64/spate_app (built on Windows)
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
LD="-s -w -X spate/internal/version.Version=$VERSION"
obf_require_garble   # SPATE_OBFUSCATE=1 without garble fails loud, never ships plain

echo "==> spate.exe (CLI)"
cmd="$(go_build_cmd cli)"
# shellcheck disable=SC2086
(cd "$ROOT" && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 $cmd -ldflags "$LD" -o "$OUT/spate.exe" ./cmd/spate)
echo "==> spate-host.exe (native messaging host)"
cmd="$(go_build_cmd cli)"
# shellcheck disable=SC2086
(cd "$ROOT" && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 $cmd -ldflags "$LD" -o "$OUT/spate-host.exe" ./cmd/spate-host)
echo "==> spate.dll (core, C ABI)"
# Export only the Spate* C ABI: mingw ld takes a .def as a linker input.
DEF="$(mktemp "${TMPDIR:-/tmp}/spate-exports.XXXXXX")"; mv "$DEF" "$DEF.def"; DEF="$DEF.def"
trap 'rm -f "$DEF"' EXIT
"$ROOT/scripts/export-symbols.sh" def > "$DEF"
cmd="$(go_build_cmd lib)"
# The .def is handed to the external linker. On native Windows (Git Bash) the
# linker is a native binary that cannot resolve a POSIX /tmp path, so give it a
# Windows path; cygpath is absent on the macOS/Linux cross-build, where $DEF is
# already native.
DEF_LD="$DEF"; command -v cygpath >/dev/null 2>&1 && DEF_LD="$(cygpath -m "$DEF")"
# shellcheck disable=SC2086
(cd "$ROOT" && GOOS=windows GOARCH=amd64 CGO_ENABLED=1 CC="$CC" $cmd -ldflags "$LD -extldflags=$DEF_LD" -buildmode=c-shared -o "$OUT/spate.dll" ./export/cshared)

echo "==> spate-setup.exe (single-file installer embedding the binaries + extension)"
PAY="$ROOT/cmd/spate-setup/payload"
rm -rf "$PAY" && mkdir -p "$PAY/bin" "$PAY/extension"
if obf_on; then
  "$ROOT/scripts/verify-obfuscation.sh" "$OUT/spate.exe" "$OUT/spate-host.exe" "$OUT/spate.dll"
fi
cp "$OUT/spate-host.exe" "$OUT/spate.exe" "$OUT/spate.dll" "$ROOT/browser/extension/store-ids.env" "$PAY/bin/"
ZIP="spate-windows-amd64.zip"
if ui_bundle_ok "$OUT"; then
  cp "$OUT/spate.dll" "$OUT/spate_app/spate.dll"   # the bundle carries the core this build just stamped
  cp -R "$OUT/spate_app" "$PAY/bin/spate_app"
elif allow_no_ui; then
  echo "==> CLI-only build: no Flutter Windows UI (SPATE_ALLOW_NO_UI=1)"
  ZIP="spate-windows-amd64-cli-only.zip"
else
  ui_bundle_missing_message "$OUT" >&2
  exit 1
fi
cp -R "$ROOT/browser/extension/." "$PAY/extension/"
cmd="$(go_build_cmd cli)"
# shellcheck disable=SC2086
(cd "$ROOT" && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 $cmd -ldflags "$LD" -o "$OUT/spate-setup.exe" ./cmd/spate-setup)

echo "==> packaging"
cp -R "$ROOT/browser/extension" "$OUT/extension"
cp "$ROOT/scripts/install-windows.ps1" "$ROOT/scripts/flutter-windows.ps1" "$OUT/"
cat > "$OUT/README-windows.txt" <<'TXT'
Spate for Windows (amd64) -- dev build

Quick start: double-click spate-setup.exe. It installs to
%LOCALAPPDATA%\Spate, registers the browser native host (Chrome, Chromium,
Edge, Brave), adds a hidden autostart, and launches the app. Then load the
extension it extracted (chrome://extensions -> Developer mode -> Load unpacked
-> %LOCALAPPDATA%\Spate\extension). If the extension's Options page shows a
different ID than setup printed, run: spate-setup.exe --extension-id <ID>
Windows SmartScreen will warn: the binaries are unsigned.

  spate-setup.exe --uninstall   removes it again

Running setup again reinstalls the same version or upgrades an older one
(settings and downloads are kept); an older setup than the installed version
is refused (--force overrides).

Manual alternative: install-windows.ps1 (same steps via PowerShell).
spate.exe is the command-line downloader. spate.dll is the core for the
Flutter UI, which you build on Windows with flutter-windows.ps1; the build
refuses to package without it. A CLI-only build (SPATE_ALLOW_NO_UI=1)
has no spate_app\, and its spate-setup.exe needs --no-ui to install.
TXT
(cd "$ROOT/dist" && rm -f spate-windows-amd64.zip spate-windows-amd64-cli-only.zip &&
  if command -v zip >/dev/null; then zip -qr "$ZIP" windows-amd64; else 7z a -tzip -bso0 "$ZIP" windows-amd64; fi)
ls -la "$OUT" "$ROOT/dist/$ZIP"
