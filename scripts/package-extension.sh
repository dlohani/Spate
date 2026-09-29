#!/usr/bin/env bash
# Package the browser extension for a store upload:
#   dist/cascade-extension-<version>.zip
# Sets the manifest version from VERSION first (stores require a new version
# per upload). Upload it at https://chrome.google.com/webstore/devconsole
# (Chrome, Brave, Vivaldi, Chromium) and https://partner.microsoft.com/dashboard
# (Edge), then put the assigned IDs in browser/extension/store-ids.env; see
# browser/STORE.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
EXT="$ROOT/browser/extension"
python3 - "$EXT/manifest.json" "$VERSION" <<'EOF'
import json, sys
p, v = sys.argv[1], sys.argv[2]
d = json.load(open(p))
if d.get("version") != v:
    d["version"] = v
    json.dump(d, open(p, "w"), indent=2)
    open(p, "a").write("\n")
    print(f"    manifest version -> {v}")
EOF
OUT="$ROOT/dist/cascade-extension-$VERSION.zip"
mkdir -p "$ROOT/dist"; rm -f "$OUT"
# store-ids.env is installer metadata, not part of the extension.
(cd "$EXT" && zip -qr "$OUT" . -x 'store-ids.env' -x '.*' -x '*/.*')
shasum -a 256 "$OUT" | tee "$OUT.sha256"
echo "==> $OUT"
