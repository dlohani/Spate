# Shared by the Windows build and packaging scripts: is the Flutter Windows
# bundle present and complete, and did the caller explicitly allow a build
# without it? Source it; bash 3.2 compatible.

# ui_bundle_ok DIR: 0 when DIR/spate_app holds the app exe and the core DLL
# the Dart loader needs beside it; 1 otherwise (a half-copied folder counts
# as missing).
ui_bundle_ok() {
  [ -f "$1/spate_app/spate_app.exe" ] && [ -f "$1/spate_app/spate.dll" ]
}

# allow_no_ui: 0 only when SPATE_ALLOW_NO_UI is exactly "1".
allow_no_ui() {
  [ "${SPATE_ALLOW_NO_UI:-}" = "1" ]
}

# ui_bundle_missing_message DIR: what to print when the bundle is missing.
ui_bundle_missing_message() {
  cat <<MSG
error: the Flutter Windows UI is not at $1/spate_app (needs spate_app.exe and spate.dll).
  Build it on Windows:  powershell -ExecutionPolicy Bypass -File scripts\\flutter-windows.ps1 -CopyTo <this checkout>
  then run this build again. For a CLI-only artifact without the UI, set SPATE_ALLOW_NO_UI=1.
MSG
}
