#!/usr/bin/env bash
# Install Cascade on macOS from this checkout: the app in ~/Applications, the
# browser native-messaging host and helpers under
# ~/Library/Application Support/cascade, browser registration, login item.
#
#   scripts/install-macos.sh [EXTENSION_ID ...]
#
# Re-running is safe: the same version reinstalls, a newer one upgrades, an
# older one is refused (CASCADE_FORCE=1 overrides). Settings, the pairing
# token and downloads are never touched. CASCADE_NO_LOGIN=1 skips the login
# item. EXTENSION_ID defaults to the ID Chromium derives for the unpacked
# extension at browser/extension in this checkout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/version.sh"
. "$ROOT/scripts/lib/extension.sh"
load_store_ids "$ROOT"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
SUPPORT="$HOME/Library/Application Support/cascade"
BIN="$SUPPORT/bin"
APP="$HOME/Applications/Cascade.app"
HOST_NAME="com.cascade.host"
DEFAULT_EXT_ID="kamlaafhjnegfjdbnfajbanjfkemefga"
EXT_IDS=("${@:-$DEFAULT_EXT_ID}")
LDFLAGS="-X cascade/internal/version.Version=$VERSION"

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
(cd "$ROOT" && go build -ldflags "$LDFLAGS" -o "$BIN/cascade-host" ./cmd/cascade-host)
cp "$ROOT/packaging/macos/bin/register-extension" "$ROOT/packaging/macos/bin/uninstall" "$BIN/"
chmod +x "$BIN/cascade-host" "$BIN/register-extension" "$BIN/uninstall"
echo "    $BIN/cascade-host"

# Stop whatever is running before files are replaced, so nothing (including
# the browser's native host) keeps an old copy alive across the swap.
echo "==> stopping running instance"
launchctl bootout "gui/$(id -u)/dev.d3xt3r.cascade" >/dev/null 2>&1 || true
pkill -x cascade_app >/dev/null 2>&1 || true   # by process name; a -f pattern could match a shell
pkill -x cascade-mac >/dev/null 2>&1 || true
sleep 1

echo "==> installing app"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R "$FLUTTER_APP" "$APP"
# One copy only: older installs kept a second bundle and a Fyne binary here.
rm -rf "$BIN/Cascade.app" "$BIN/cascade-mac"
echo "    $APP  ($VERSION)"

origins="$(ext_origins "${EXT_IDS[@]}")"
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
register_firefox_host_macos "$BIN/cascade-host"
echo "==> browser extension"
register_store_extension_macos

# Start at login (hidden, menu bar only) via a per-user LaunchAgent. Skip with
# CASCADE_NO_LOGIN=1. Remove with: launchctl bootout gui/$UID/dev.d3xt3r.cascade
if [ "${CASCADE_NO_LOGIN:-0}" != "1" ]; then
  echo "==> registering login item (LaunchAgent)"
  LA="$HOME/Library/LaunchAgents"; mkdir -p "$LA"
  PLIST="$LA/dev.d3xt3r.cascade.plist"
  cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>dev.d3xt3r.cascade</string>
  <key>ProgramArguments</key>
  <array><string>${APP}/Contents/MacOS/cascade_app</string><string>--background</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>CASCADE_BACKGROUND</key><string>1</string></dict>
  <key>RunAtLoad</key><true/>
</dict></plist>
PL
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
  echo "    $PLIST (starts Cascade hidden at login; started now)"
else
  open -a "$APP" --args --background || true
fi

echo "==> done. Cascade $VERSION. Extension IDs allowed: ${EXT_IDS[*]}"
echo "    Open it from Spotlight/Launchpad (Cascade) or the menu-bar icon."
extension_next_step "$ROOT/browser/extension"
echo "    Remove with: $BIN/uninstall"
