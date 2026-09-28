#!/usr/bin/env bash
# Install Cascade on Linux (run ON a Linux machine): the Go core as a shared
# library, the browser native-messaging host, the Flutter app bundle (if built),
# browser host manifests, an application menu entry, and autostart at login.
#
#   scripts/install-linux.sh [EXTENSION_ID ...]
#
# Prerequisites: Go, and for the UI `flutter build linux` (needs clang, cmake,
# ninja, pkg-config, libgtk-3-dev). Chromium-family browsers only; a Firefox
# extension variant is a follow-up.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${XDG_DATA_HOME:-$HOME/.local/share}/cascade/bin"
HOST_NAME="com.cascade.host"
DEFAULT_EXT_ID="kamlaafhjnegfjdbnfajbanjfkemefga"
EXT_IDS=("${@:-$DEFAULT_EXT_ID}")

echo "==> building"
mkdir -p "$BIN"
(cd "$ROOT" && go build -o "$BIN/cascade-host" ./cmd/cascade-host)
(cd "$ROOT" && CGO_ENABLED=1 go build -buildmode=c-shared -o "$BIN/libcascade.so" ./export/cshared)
chmod +x "$BIN/cascade-host"
echo "    $BIN/cascade-host"
echo "    $BIN/libcascade.so"

# Flutter bundle (preferred by the native host when present).
BUNDLE="$(ls -d "$ROOT"/apps/flutter/build/linux/*/release/bundle 2>/dev/null | head -1 || true)"
if [ -n "$BUNDLE" ]; then
  rm -rf "$BIN/cascade_app"
  cp -R "$BUNDLE" "$BIN/cascade_app"
  cp "$BIN/libcascade.so" "$BIN/cascade_app/lib/libcascade.so"   # loader looks in <exe>/lib
  echo "    $BIN/cascade_app/cascade_app  (Flutter UI)"
else
  echo "    (no Flutter Linux bundle found; run 'flutter build linux' in apps/flutter first)"
fi

origins=""
for id in "${EXT_IDS[@]}"; do origins+="${origins:+, }\"chrome-extension://${id}/\""; done
manifest="{
  \"name\": \"${HOST_NAME}\",
  \"description\": \"Cascade download manager native host\",
  \"path\": \"${BIN}/cascade-host\",
  \"type\": \"stdio\",
  \"allowed_origins\": [${origins}]
}"

echo "==> registering native messaging host for installed browsers"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
for dir in \
  "$CFG/chromium/NativeMessagingHosts" \
  "$CFG/google-chrome/NativeMessagingHosts" \
  "$CFG/google-chrome-beta/NativeMessagingHosts" \
  "$CFG/BraveSoftware/Brave-Browser/NativeMessagingHosts" \
  "$CFG/microsoft-edge/NativeMessagingHosts" \
  "$CFG/vivaldi/NativeMessagingHosts" \
  "$HOME/snap/chromium/common/chromium/NativeMessagingHosts"; do
  parent="$(dirname "$dir")"
  [ -d "$parent" ] || continue
  mkdir -p "$dir"
  printf '%s\n' "$manifest" > "$dir/${HOST_NAME}.json"
  echo "    $dir/${HOST_NAME}.json"
done

if [ -n "$BUNDLE" ]; then
  echo "==> application menu entry + autostart (hidden, tray only)"
  APPS="$CFG/../.local/share/applications"; APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  AUTO="$CFG/autostart"
  mkdir -p "$APPS" "$AUTO"
  cat > "$APPS/cascade.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=Cascade
Comment=Download manager
Exec=${BIN}/cascade_app/cascade_app
Icon=folder-download
Terminal=false
Categories=Network;FileTransfer;
DESK
  cat > "$AUTO/cascade.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=Cascade
Exec=${BIN}/cascade_app/cascade_app --background
Terminal=false
X-GNOME-Autostart-enabled=true
DESK
  echo "    $APPS/cascade.desktop"
  echo "    $AUTO/cascade.desktop"
fi

echo "==> done. Extension IDs allowed: ${EXT_IDS[*]}"
echo "    Load browser/extension in chrome://extensions (Developer mode -> Load unpacked)."
echo "    Note: a tray icon needs a desktop that supports AppIndicator (KDE, or GNOME with the extension)."
