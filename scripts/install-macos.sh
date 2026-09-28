#!/usr/bin/env bash
# Install Cascade on macOS: the resident app, the browser native-messaging host,
# and the host manifests that let the extension launch the app on demand.
#
#   scripts/install-macos.sh [EXTENSION_ID ...]
#
# EXTENSION_ID defaults to the ID Chromium derives for the unpacked extension at
# browser/extension in this checkout. If you load the extension from another
# path (or it is packaged), pass its ID as shown on chrome://extensions.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$HOME/Library/Application Support/cascade/bin"
HOST_NAME="com.cascade.host"
DEFAULT_EXT_ID="kamlaafhjnegfjdbnfajbanjfkemefga"
EXT_IDS=("${@:-$DEFAULT_EXT_ID}")

export PATH="/opt/homebrew/bin:/usr/local/go/bin:$PATH"

echo "==> building"
mkdir -p "$BIN"
(cd "$ROOT" && go build -o "$BIN/cascade-host" ./cmd/cascade-host)
(cd "$ROOT/apps/macapp" && go build -o "$BIN/cascade-mac" . 2> >(grep -v "duplicate librar" >&2 || true))
chmod +x "$BIN/cascade-host" "$BIN/cascade-mac"
echo "    $BIN/cascade-mac"
echo "    $BIN/cascade-host"

# Flutter app bundle (preferred by the native host when present). Built by
# scripts/flutter-macos.sh build; installed here as Cascade.app.
FLUTTER_APP="$(ls -d "$ROOT"/apps/flutter/build/macos/Build/Products/Release/*.app 2>/dev/null | head -1 || true)"
if [ -n "$FLUTTER_APP" ]; then
  rm -rf "$BIN/Cascade.app"
  cp -R "$FLUTTER_APP" "$BIN/Cascade.app"
  echo "    $BIN/Cascade.app  (Flutter UI; launched on demand by the native host)"
fi

origins=""
for id in "${EXT_IDS[@]}"; do
  origins+="${origins:+, }\"chrome-extension://${id}/\""
done
manifest="{
  \"name\": \"${HOST_NAME}\",
  \"description\": \"Cascade download manager native host\",
  \"path\": \"${BIN}/cascade-host\",
  \"type\": \"stdio\",
  \"allowed_origins\": [${origins}]
}"

echo "==> registering native messaging host for installed browsers"
AS="$HOME/Library/Application Support"
for dir in \
  "$AS/Chromium/NativeMessagingHosts" \
  "$AS/Google/Chrome/NativeMessagingHosts" \
  "$AS/BraveSoftware/Brave-Browser/NativeMessagingHosts" \
  "$AS/Microsoft Edge/NativeMessagingHosts" \
  "$AS/Vivaldi/NativeMessagingHosts"; do
  parent="$(dirname "$dir")"
  [ -d "$parent" ] || continue
  mkdir -p "$dir"
  printf '%s\n' "$manifest" > "$dir/${HOST_NAME}.json"
  echo "    $dir/${HOST_NAME}.json"
done

echo "==> done. Extension IDs allowed: ${EXT_IDS[*]}"
echo "    Load browser/extension in chrome://extensions (Developer mode -> Load unpacked)."
echo "    Downloads will launch $BIN/cascade-mac automatically when it is not running."
