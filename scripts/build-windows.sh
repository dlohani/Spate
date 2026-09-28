#!/usr/bin/env bash
# Cross-compile the Windows (amd64) binaries from macOS/Linux and package them:
#   cascade.exe        CLI (pure Go)
#   cascade-host.exe   browser native-messaging host (pure Go)
#   cascade.dll/.h     the core as a C shared library (needs mingw-w64)
#   cascade-gui.exe    Fyne desktop UI with the core embedded (needs mingw-w64)
# The Flutter Windows UI must be built on Windows: see scripts/flutter-windows.ps1.
#
#   brew install mingw-w64   (once)
#   scripts/build-windows.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/go/bin:$PATH"
OUT="$ROOT/dist/windows-amd64"
CC=x86_64-w64-mingw32-gcc
command -v "$CC" >/dev/null || { echo "missing $CC: brew install mingw-w64"; exit 1; }
rm -rf "$OUT" && mkdir -p "$OUT"

echo "==> cascade.exe (CLI)"
(cd "$ROOT" && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -ldflags "-s -w" -o "$OUT/cascade.exe" ./cmd/cascade)
echo "==> cascade-host.exe (native messaging host)"
(cd "$ROOT" && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -ldflags "-s -w" -o "$OUT/cascade-host.exe" ./cmd/cascade-host)
echo "==> cascade.dll (core, C ABI)"
(cd "$ROOT" && GOOS=windows GOARCH=amd64 CGO_ENABLED=1 CC="$CC" go build -buildmode=c-shared -o "$OUT/cascade.dll" ./export/cshared)
echo "==> cascade-gui.exe (Fyne UI; first build compiles GLFW, takes a while)"
(cd "$ROOT/apps/macapp" && GOOS=windows GOARCH=amd64 CGO_ENABLED=1 CC="$CC" go build -ldflags "-s -w -H windowsgui" -o "$OUT/cascade-gui.exe" .)

echo "==> packaging"
cp -R "$ROOT/browser/extension" "$OUT/extension"
cp "$ROOT/scripts/install-windows.ps1" "$ROOT/scripts/flutter-windows.ps1" "$OUT/"
cat > "$OUT/README-windows.txt" <<'TXT'
Cascade for Windows (amd64) -- test build

1. Right-click install-windows.ps1 -> Run with PowerShell
   (or: powershell -ExecutionPolicy Bypass -File install-windows.ps1)
   Installs to %LOCALAPPDATA%\Cascade\bin, registers the browser native host
   (Chrome, Chromium, Edge, Brave) in the registry, and adds a Run-key autostart.
2. Load the extension: chrome://extensions -> Developer mode -> Load unpacked
   -> the "extension" folder.
3. Start cascade-gui.exe (or download something in the browser: the host
   launches it). Windows SmartScreen may warn: the binaries are unsigned.

cascade.exe is the command-line downloader. cascade.dll is the core for the
Flutter UI, which you build on Windows with flutter-windows.ps1.
TXT
(cd "$ROOT/dist" && rm -f cascade-windows-amd64.zip && zip -qr cascade-windows-amd64.zip windows-amd64)
ls -la "$OUT" "$ROOT/dist/cascade-windows-amd64.zip"
