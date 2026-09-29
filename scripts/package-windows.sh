#!/usr/bin/env bash
# Build the Windows installer with NSIS (cross-platform, runs on macOS/Linux):
#   dist/Cascade-Setup-<version>.exe
# Uses the cross-compiled binaries from scripts/build-windows.sh (run it first,
# or this script runs it when they are missing). To ship the Flutter UI too,
# place its Release folder at dist/windows-amd64/cascade_app before building.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:$PATH"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
. "$ROOT/scripts/lib/extension.sh"
load_store_ids "$ROOT"
command -v makensis >/dev/null || { echo "missing makensis: brew install makensis"; exit 1; }
[ -f "$ROOT/dist/windows-amd64/cascade-gui.exe" ] || "$ROOT/scripts/build-windows.sh"
(cd "$ROOT/packaging/windows" && makensis -V2 -DVERSION="$VERSION" -DCHROME_WEBSTORE_ID="${CHROME_WEBSTORE_ID:-}" -DEDGE_ADDONS_ID="${EDGE_ADDONS_ID:-}" cascade.nsi)
OUT="$ROOT/dist/Cascade-Setup-$VERSION.exe"
shasum -a 256 "$OUT" | tee "$OUT.sha256"
echo "==> $OUT (unsigned: SmartScreen will warn on first run)"
