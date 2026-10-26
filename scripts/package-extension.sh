#!/usr/bin/env bash
# Package the browser extension for every browser family:
#
#   dist/spate-extension-<version>.zip          Chrome Web Store / Edge Add-ons upload
#   dist/spate-extension-firefox-<version>.zip  addons.mozilla.org upload (unlisted signing)
#   dist/firefox-extension/                       unpacked, for about:debugging "Load Temporary Add-on"
#   dist/safari-extension/                        source for scripts/safari-extension.sh (Xcode)
#
# One code base: browser/extension with manifest.json (Chrome MV3),
# manifest.firefox.json (MV2 event page) and manifest.safari.json. The
# manifest versions are set from VERSION first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
EXT="$ROOT/browser/extension"
DIST="$ROOT/dist"; mkdir -p "$DIST"

python3 - "$VERSION" "$EXT/manifest.json" "$EXT/manifest.firefox.json" "$EXT/manifest.safari.json" <<'EOF'
import json, sys
v = sys.argv[1]
for p in sys.argv[2:]:
    d = json.load(open(p))
    if d.get("version") != v:
        d["version"] = v
        json.dump(d, open(p, "w"), indent=2)
        open(p, "a").write("\n")
        print(f"    {p.rsplit('/', 1)[1]} version -> {v}")
EOF

# Common files; store-ids.env is installer metadata, capture.js is Safari-only.
common() { # dest-dir manifest-file [extra-file...]
  local dest="$1" manifest="$2"; shift 2
  rm -rf "$dest"; mkdir -p "$dest/icons"
  cp "$EXT"/*.js "$EXT"/*.html "$dest/"
  cp "$EXT"/icons/*.png "$dest/icons/"
  rm -f "$dest/capture.js"
  for f in "$@"; do cp "$EXT/$f" "$dest/"; done
  cp "$EXT/$manifest" "$dest/manifest.json"
}

echo "==> chrome (also Edge, Brave, Vivaldi, Chromium)"
common "$DIST/chrome-extension" manifest.json
OUT="$DIST/spate-extension-$VERSION.zip"; rm -f "$OUT"
(cd "$DIST/chrome-extension" && zip -qr "$OUT" .)
shasum -a 256 "$OUT" | tee "$OUT.sha256"

echo "==> firefox"
common "$DIST/firefox-extension" manifest.firefox.json
OUT="$DIST/spate-extension-firefox-$VERSION.zip"; rm -f "$OUT"
(cd "$DIST/firefox-extension" && zip -qr "$OUT" .)
shasum -a 256 "$OUT" | tee "$OUT.sha256"
echo "    unpacked: $DIST/firefox-extension (about:debugging -> This Firefox -> Load Temporary Add-on -> manifest.json)"

echo "==> safari (source for scripts/safari-extension.sh)"
common "$DIST/safari-extension" manifest.safari.json capture.js
echo "    $DIST/safari-extension"
