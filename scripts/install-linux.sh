#!/usr/bin/env bash
# Install Spate on Linux (run ON a Linux machine): the Go core as a shared
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
. "$ROOT/scripts/lib/version.sh"
. "$ROOT/scripts/lib/extension.sh"
load_store_ids "$ROOT"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/spate"
BIN="$DATA/bin"
HOST_NAME="com.amlabs.spate.host"
DEFAULT_EXT_ID="kamlaafhjnegfjdbnfajbanjfkemefga"
EXT_IDS=("${@:-$DEFAULT_EXT_ID}")
LDFLAGS="-X spate/internal/version.Version=$VERSION"

# Re-running is safe: same version reinstalls, newer upgrades, older is
# refused (SPATE_FORCE=1 overrides). Settings and downloads are kept.
check_install_version "$(installed_version_linux)" "$VERSION"

echo "==> building"
mkdir -p "$BIN"
(cd "$ROOT" && go build -ldflags "$LDFLAGS" -o "$BIN/spate-host.new" ./cmd/spate-host)
MAP="$(mktemp "${TMPDIR:-/tmp}/spate-exports.XXXXXX")"; trap 'rm -f "$MAP"' EXIT
"$ROOT/scripts/export-symbols.sh" gnu > "$MAP"   # export only the Spate* C ABI
(cd "$ROOT" && CGO_ENABLED=1 go build -ldflags "$LDFLAGS -extldflags=-Wl,--version-script,$MAP" -buildmode=c-shared -o "$BIN/libspate.so.new" ./export/cshared)

# Stop a running instance before replacing its files.
pkill -x spate_app >/dev/null 2>&1 || true   # by process name; a -f pattern could match a shell
# A previous install under the old product name (Cascade): stop it and drop
# its binaries, menu and autostart entries and host manifests. Its settings,
# token and queue under ~/.config/cascade are migrated on first start.
pkill -x cascade_app >/dev/null 2>&1 || true
rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/cascade/bin"
rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/applications/cascade.desktop" "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/cascade.desktop"
find "${XDG_CONFIG_HOME:-$HOME/.config}" "$HOME/snap/chromium/common/chromium" "$HOME/.mozilla" -path "*NativeMessagingHosts/com.cascade.host.json" -delete 2>/dev/null || true
sleep 1
mv -f "$BIN/spate-host.new" "$BIN/spate-host"
mv -f "$BIN/libspate.so.new" "$BIN/libspate.so"
chmod +x "$BIN/spate-host"
echo "    $BIN/spate-host"
echo "    $BIN/libspate.so"

# Flutter bundle (preferred by the native host when present).
BUNDLE="$(ls -d "$ROOT"/apps/flutter/build/linux/*/release/bundle 2>/dev/null | head -1 || true)"
if [ -n "$BUNDLE" ]; then
  rm -rf "$BIN/spate_app"
  cp -R "$BUNDLE" "$BIN/spate_app"
  cp "$BIN/libspate.so" "$BIN/spate_app/lib/libspate.so"   # loader looks in <exe>/lib
  echo "    $BIN/spate_app/spate_app  (Flutter UI)"
else
  echo "    (no Flutter Linux bundle found; run 'flutter build linux' in apps/flutter first)"
fi

origins="$(ext_origins "${EXT_IDS[@]}")"
manifest="{
  \"name\": \"${HOST_NAME}\",
  \"description\": \"Spate download manager native host\",
  \"path\": \"${BIN}/spate-host\",
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
register_firefox_host_linux "$BIN/spate-host"
echo "==> browser extension"
register_store_extension_linux

if [ -n "$BUNDLE" ]; then
  echo "==> application menu entry + autostart (hidden, tray only)"
  APPS="$CFG/../.local/share/applications"; APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
  AUTO="$CFG/autostart"
  mkdir -p "$APPS" "$AUTO"
  cat > "$APPS/spate.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=Spate
Comment=Download manager
Exec=${BIN}/spate_app/spate_app
Icon=folder-download
Terminal=false
Categories=Network;FileTransfer;
DESK
  cat > "$AUTO/spate.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=Spate
Exec=${BIN}/spate_app/spate_app --background
Terminal=false
X-GNOME-Autostart-enabled=true
DESK
  echo "    $APPS/spate.desktop"
  echo "    $AUTO/spate.desktop"
fi

printf '%s\n' "$VERSION" > "$DATA/VERSION"   # read by the next install's version check
echo "==> done. Spate $VERSION. Extension IDs allowed: ${EXT_IDS[*]}"
extension_next_step "$ROOT/browser/extension"
echo "    Note: a tray icon needs a desktop that supports AppIndicator (KDE, or GNOME with the extension)."
