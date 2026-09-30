#!/usr/bin/env bash
# Tests for scripts/lib/bundle.sh. Each check prints "  not ok: <what>" on failure.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/lib/bundle.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
rc=0
check() { # DESCRIPTION EXPECTED_STATUS ACTUAL_STATUS
  if [ "$2" != "$3" ]; then echo "  not ok: $1 (want $2, got $3)"; rc=1; fi
}

# ui_bundle_ok
ui_bundle_ok "$TMP"; check "no cascade_app folder is missing" 1 $?
mkdir -p "$TMP/cascade_app"
ui_bundle_ok "$TMP"; check "empty cascade_app folder is missing" 1 $?
: > "$TMP/cascade_app/cascade_app.exe"
ui_bundle_ok "$TMP"; check "exe without cascade.dll is missing" 1 $?
: > "$TMP/cascade_app/cascade.dll"
ui_bundle_ok "$TMP"; check "exe and dll present is ok" 0 $?

# allow_no_ui
( unset CASCADE_ALLOW_NO_UI; allow_no_ui ); check "unset does not allow" 1 $?
( CASCADE_ALLOW_NO_UI=0 allow_no_ui );    check "0 does not allow" 1 $?
( CASCADE_ALLOW_NO_UI=true allow_no_ui ); check "true does not allow" 1 $?
( CASCADE_ALLOW_NO_UI=yes allow_no_ui );  check "yes does not allow" 1 $?
( CASCADE_ALLOW_NO_UI=1 allow_no_ui );    check "1 allows" 0 $?

# message names the folder and the override
msg="$(ui_bundle_missing_message "$TMP")"
case "$msg" in *"$TMP/cascade_app"*) ;; *) echo "  not ok: message names the folder"; rc=1 ;; esac
case "$msg" in *CASCADE_ALLOW_NO_UI=1*) ;; *) echo "  not ok: message names the override"; rc=1 ;; esac
case "$msg" in *flutter-windows.ps1*) ;; *) echo "  not ok: message names the build script"; rc=1 ;; esac
exit $rc
