# Shared by the install scripts: store-published extension registration and
# the native host's allowed origins. Source it; bash 3.2 compatible.
#
# Browsers only install extensions that come from a store; an installer may
# *register* one (a preferences file per browser on macOS/Linux, a registry
# key on Windows) and the browser fetches it from the store on next start.

CHROME_UPDATE_URL="https://clients2.google.com/service/update2/crx"
EDGE_UPDATE_URL="https://edge.microsoft.com/extensionwebstorebase/v1/crx"
DEV_EXT_ID="kamlaafhjnegfjdbnfajbanjfkemefga"
# Firefox uses a fixed add-on ID (browser_specific_settings.gecko.id), so its
# native host manifest needs no derived or store IDs.
FIREFOX_EXT_ID="cascade@d3xt3r.dev"

# firefox_host_manifest HOST_PATH: Firefox's variant of the native host
# manifest (allowed_extensions instead of allowed_origins).
firefox_host_manifest() {
  printf '{\n  "name": "com.cascade.host",\n  "description": "Cascade download manager native host",\n  "path": "%s",\n  "type": "stdio",\n  "allowed_extensions": ["%s"]\n}\n' "$1" "$FIREFOX_EXT_ID"
}

# register_firefox_host_macos HOST_PATH: per-user registration when Firefox
# is installed or has a profile folder.
register_firefox_host_macos() {
  local AS="$HOME/Library/Application Support"
  { [ -d "$AS/Firefox" ] || [ -d "/Applications/Firefox.app" ] || [ -d "$HOME/Applications/Firefox.app" ]; } || return 0
  mkdir -p "$AS/Mozilla/NativeMessagingHosts"
  firefox_host_manifest "$1" > "$AS/Mozilla/NativeMessagingHosts/com.cascade.host.json"
  echo "    $AS/Mozilla/NativeMessagingHosts/com.cascade.host.json (Firefox)"
}

# register_firefox_host_linux HOST_PATH: per-user registration.
register_firefox_host_linux() {
  { [ -d "$HOME/.mozilla" ] || command -v firefox >/dev/null 2>&1; } || return 0
  mkdir -p "$HOME/.mozilla/native-messaging-hosts"
  firefox_host_manifest "$1" > "$HOME/.mozilla/native-messaging-hosts/com.cascade.host.json"
  echo "    $HOME/.mozilla/native-messaging-hosts/com.cascade.host.json (Firefox)"
}

# load_store_ids ROOT: sets CHROME_WEBSTORE_ID / EDGE_ADDONS_ID (may be empty).
load_store_ids() {
  CHROME_WEBSTORE_ID=""; EDGE_ADDONS_ID=""
  local f="$1/browser/extension/store-ids.env"
  [ -f "$f" ] || f="$1/extension/store-ids.env"
  [ -f "$f" ] || return 0
  # shellcheck disable=SC1090
  . "$f"
}

# derive_ext_id PATH: Chrome's ID for an unpacked extension folder
# (sha256 of the absolute path, first 32 hex digits mapped a-p).
derive_ext_id() {
  if command -v shasum >/dev/null; then
    printf '%s' "$1" | shasum -a 256 | cut -c1-32 | tr '0123456789abcdef' 'abcdefghijklmnop'
  else
    printf '%s' "$1" | sha256sum | cut -c1-32 | tr '0123456789abcdef' 'abcdefghijklmnop'
  fi
}

# ext_origins ID...: the allowed_origins JSON list for the native host
# manifest: the dev ID, the store IDs when known, and any given IDs.
ext_origins() {
  local ids="$DEV_EXT_ID ${CHROME_WEBSTORE_ID:-} ${EDGE_ADDONS_ID:-} $*" out="" id seen=" "
  for id in $ids; do
    case "$seen" in *" $id "*) continue ;; esac
    seen="$seen$id "
    out+="${out:+, }\"chrome-extension://${id}/\""
  done
  printf '%s' "$out"
}

# register_store_extension_macos: for each Chromium-family browser present
# (app bundle or profile folder), write the External Extensions entry so the
# browser installs the store extension. No-op until the IDs are set.
register_store_extension_macos() {
  local AS="$HOME/Library/Application Support" n=0
  _reg() { # support-dir app-bundle id update-url
    [ -n "$3" ] || return 0
    { [ -d "$AS/$1" ] || [ -d "/Applications/$2" ] || [ -d "$HOME/Applications/$2" ]; } || return 0
    mkdir -p "$AS/$1/External Extensions"
    printf '{ "external_update_url": "%s" }\n' "$4" > "$AS/$1/External Extensions/$3.json"
    echo "    extension registered for ${2%.app} (installs from the store on next start)"
    n=$((n + 1))
  }
  _reg "Google/Chrome" "Google Chrome.app" "${CHROME_WEBSTORE_ID:-}" "$CHROME_UPDATE_URL"
  _reg "Chromium" "Chromium.app" "${CHROME_WEBSTORE_ID:-}" "$CHROME_UPDATE_URL"
  _reg "BraveSoftware/Brave-Browser" "Brave Browser.app" "${CHROME_WEBSTORE_ID:-}" "$CHROME_UPDATE_URL"
  _reg "Vivaldi" "Vivaldi.app" "${CHROME_WEBSTORE_ID:-}" "$CHROME_UPDATE_URL"
  _reg "Microsoft Edge" "Microsoft Edge.app" "${EDGE_ADDONS_ID:-}" "$EDGE_UPDATE_URL"
  if [ "$n" = 0 ] && [ -n "${CHROME_WEBSTORE_ID:-}${EDGE_ADDONS_ID:-}" ]; then
    echo "    (no Chromium-family browser found to register the extension with)"
  fi
}

# register_store_extension_linux: per-user equivalent (~/.config/<browser>).
register_store_extension_linux() {
  local CFG="${XDG_CONFIG_HOME:-$HOME/.config}" n=0
  _reg() { # config-dir binary id update-url
    [ -n "$3" ] || return 0
    { [ -d "$CFG/$1" ] || command -v "$2" >/dev/null 2>&1; } || return 0
    mkdir -p "$CFG/$1/External Extensions"
    printf '{ "external_update_url": "%s" }\n' "$4" > "$CFG/$1/External Extensions/$3.json"
    echo "    extension registered for $2 (installs from the store on next start)"
    n=$((n + 1))
  }
  _reg "google-chrome" "google-chrome" "${CHROME_WEBSTORE_ID:-}" "$CHROME_UPDATE_URL"
  _reg "chromium" "chromium" "${CHROME_WEBSTORE_ID:-}" "$CHROME_UPDATE_URL"
  _reg "BraveSoftware/Brave-Browser" "brave-browser" "${CHROME_WEBSTORE_ID:-}" "$CHROME_UPDATE_URL"
  _reg "vivaldi" "vivaldi" "${CHROME_WEBSTORE_ID:-}" "$CHROME_UPDATE_URL"
  _reg "microsoft-edge" "microsoft-edge" "${EDGE_ADDONS_ID:-}" "$EDGE_UPDATE_URL"
  if [ "$n" = 0 ] && [ -n "${CHROME_WEBSTORE_ID:-}${EDGE_ADDONS_ID:-}" ]; then
    echo "    (no Chromium-family browser found to register the extension with)"
  fi
}

# extension_next_step: what the user still has to do, depending on whether
# the extension is published.
extension_next_step() {
  if [ -n "${CHROME_WEBSTORE_ID:-}" ]; then
    echo "    Restart the browser: it installs the Cascade extension from the store"
    echo "    (Windows/macOS show a one-time 'Enable extension' prompt)."
  else
    echo "    Load the extension: chrome://extensions -> Developer mode -> Load unpacked -> $1"
  fi
  echo "    Firefox: about:debugging -> Load Temporary Add-on -> dist/firefox-extension/manifest.json (or install the signed .xpi; see browser/STORE.md)"
}
