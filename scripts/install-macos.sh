#!/usr/bin/env bash
# Install Spate on macOS from this checkout: the app in ~/Applications, the
# browser native-messaging host and helpers under
# ~/Library/Application Support/spate, browser registration, login item.
#
#   scripts/install-macos.sh [EXTENSION_ID ...]
#
# Re-running is safe: the same version reinstalls, a newer one upgrades, an
# older one is refused (SPATE_FORCE=1 overrides). Settings, the pairing
# token and downloads are never touched. SPATE_NO_LOGIN=1 skips the login
# item. EXTENSION_ID defaults to the ID Chromium derives for the unpacked
# extension at browser/extension in this checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/version.sh"
. "$ROOT/scripts/lib/extension.sh"
load_store_ids "$ROOT"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
SUPPORT="$HOME/Library/Application Support/spate"
BIN="$SUPPORT/bin"
APP="$HOME/Applications/Spate.app"
HOST_NAME="com.amlabs.spate.host"
DEFAULT_EXT_ID="kamlaafhjnegfjdbnfajbanjfkemefga"
EXT_IDS=("${@:-$DEFAULT_EXT_ID}")
LDFLAGS="-X spate/internal/version.Version=$VERSION"

export PATH="/opt/homebrew/bin:/usr/local/go/bin:$PATH"

check_install_version "$(installed_version_macos)" "$VERSION"

FLUTTER_APP="$(ls -d "$ROOT"/apps/flutter/build/macos/Build/Products/Release/*.app 2>/dev/null | head -1 || true)"
if [ -z "$FLUTTER_APP" ]; then
  echo "    Flutter app not built; running scripts/flutter-macos.sh build"
  "$ROOT/scripts/flutter-macos.sh" build >/dev/null
  FLUTTER_APP="$(ls -d "$ROOT"/apps/flutter/build/macos/Build/Products/Release/*.app | head -1)"
fi

echo "==> building helpers"
mkdir -p "$BIN"
(cd "$ROOT" && go build -ldflags "$LDFLAGS" -o "$BIN/spate-host" ./cmd/spate-host)
cp "$ROOT/packaging/macos/bin/register-extension" "$ROOT/packaging/macos/bin/uninstall" "$BIN/"
chmod +x "$BIN/spate-host" "$BIN/register-extension" "$BIN/uninstall"
echo "    $BIN/spate-host"

# Stop whatever is running before files are replaced, so nothing (including
# the browser's native host) keeps an old copy alive across the swap.
echo "==> stopping running instance"
launchctl bootout "gui/$(id -u)/com.amlabs.spate" >/dev/null 2>&1 || true
pkill -x spate_app >/dev/null 2>&1 || true   # by process name; a -f pattern could match a shell
pkill -x spate-mac >/dev/null 2>&1 || true

# A previous install under the product's old name (Cascade): stop it, drop its
# login item, app bundle, helper binaries and browser host manifests. Its
# settings, pairing token and queue are migrated by the core on first start.
launchctl bootout "gui/$(id -u)/dev.d3xt3r.cascade" >/dev/null 2>&1 || true
rm -f "$HOME/Library/LaunchAgents/dev.d3xt3r.cascade.plist"
pkill -x cascade_app >/dev/null 2>&1 || true
rm -rf "$HOME/Applications/Cascade.app" "$HOME/Library/Application Support/cascade/bin" "$HOME/Library/Application Support/cascade/extension"
for b in Chromium Google/Chrome BraveSoftware/Brave-Browser "Microsoft Edge" Vivaldi; do
  rm -f "$HOME/Library/Application Support/$b/NativeMessagingHosts/com.cascade.host.json"
done
rm -f "$HOME/Library/Application Support/Mozilla/NativeMessagingHosts/com.cascade.host.json"
sleep 1

echo "==> installing app"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R "$FLUTTER_APP" "$APP"
# One copy only: older installs kept a second bundle and a helper binary here.
rm -rf "$BIN/Spate.app" "$BIN/spate-mac"
echo "    $APP  ($VERSION)"

origins="$(ext_origins "${EXT_IDS[@]}")"
manifest="{
  \"name\": \"${HOST_NAME}\",
  \"description\": \"Spate download manager native host\",
  \"path\": \"${BIN}/spate-host\",
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
register_firefox_host_macos "$BIN/spate-host"
echo "==> browser extension"
register_store_extension_macos

# Start at login (hidden, menu bar only) via a per-user LaunchAgent. Skip with
# SPATE_NO_LOGIN=1. Remove with: launchctl bootout gui/$UID/com.amlabs.spate
if [ "${SPATE_NO_LOGIN:-0}" != "1" ]; then
  echo "==> registering login item (LaunchAgent)"
  LA="$HOME/Library/LaunchAgents"; mkdir -p "$LA"
  PLIST="$LA/com.amlabs.spate.plist"
  cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.amlabs.spate</string>
  <key>ProgramArguments</key>
  <array><string>${APP}/Contents/MacOS/spate_app</string><string>--background</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>SPATE_BACKGROUND</key><string>1</string></dict>
  <key>RunAtLoad</key><true/>
</dict></plist>
PL
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
  echo "    $PLIST (starts Spate hidden at login; started now)"
else
  open -a "$APP" --args --background || true
fi

echo "==> done. Spate $VERSION. Extension IDs allowed: ${EXT_IDS[*]}"
echo "    Open it from Spotlight/Launchpad (Spate) or the menu-bar icon."
extension_next_step "$ROOT/browser/extension"
echo "    Remove with: $BIN/uninstall"
