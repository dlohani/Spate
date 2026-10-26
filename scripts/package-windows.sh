#!/usr/bin/env bash
# Build the Windows installer with NSIS (cross-platform, runs on macOS/Linux):
#   dist/Spate-Setup-<version>.exe
# Uses the cross-compiled binaries from scripts/build-windows.sh (run it first,
# or this script runs it when they are missing). To ship the Flutter UI too,
# place its Release folder at dist/windows-amd64/spate_app before building.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:$PATH"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
. "$ROOT/scripts/lib/extension.sh"
. "$ROOT/scripts/lib/bundle.sh"
. "$ROOT/scripts/lib/sha256.sh"
load_store_ids "$ROOT"
command -v makensis >/dev/null || { echo "missing makensis: brew install makensis"; exit 1; }
[ -f "$ROOT/dist/windows-amd64/spate-host.exe" ] || "$ROOT/scripts/build-windows.sh"
ui_bundle_ok "$ROOT/dist/windows-amd64" || { ui_bundle_missing_message "$ROOT/dist/windows-amd64" >&2; exit 1; }
(cd "$ROOT/packaging/windows" && makensis -V2 -DVERSION="$VERSION" -DCHROME_WEBSTORE_ID="${CHROME_WEBSTORE_ID:-}" -DEDGE_ADDONS_ID="${EDGE_ADDONS_ID:-}" spate.nsi)
OUT="$ROOT/dist/Spate-Setup-$VERSION.exe"
sha256_file "$OUT" | tee "$OUT.sha256"
echo "==> $OUT (unsigned: SmartScreen will warn on first run)"
