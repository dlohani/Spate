#!/usr/bin/env bash
# Build the Flutter macOS app with the Go core bundled as libcascade.dylib.
#
#   scripts/flutter-macos.sh [run|build]   (default: build)
#
# Requires full Xcode (xcode-select pointed at Xcode.app), CocoaPods, Flutter.
# The Dart loader looks for <App>.app/Contents/Frameworks/libcascade.dylib, so
# the library is copied into the bundle after `flutter build`. For `run`, the
# loader falls back to CASCADE_LIB, which is set to the freshly built dylib.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/go/bin:$PATH"
MODE="${1:-build}"

echo "==> building Go core (libcascade.dylib)"
(cd "$ROOT" && make lib >/dev/null)
DYLIB="$ROOT/dist/libcascade.dylib"
# Give the dylib an @rpath install name so the bundled copy resolves.
install_name_tool -id "@rpath/libcascade.dylib" "$DYLIB" 2>/dev/null || true

cd "$ROOT/apps/flutter"
case "$MODE" in
  run)
    CASCADE_LIB="$DYLIB" flutter run -d macos
    ;;
  build)
    flutter build macos --release
    APP="$(ls -d build/macos/Build/Products/Release/*.app | head -1)"
    mkdir -p "$APP/Contents/Frameworks"
    cp "$DYLIB" "$APP/Contents/Frameworks/libcascade.dylib"
    echo "==> bundled: $APP/Contents/Frameworks/libcascade.dylib"
    # Adding a file after Flutter signed the bundle breaks its code seal
    # ("nested code is modified"); re-sign ad hoc so the bundle is consistent.
    # Replace "-" with a Developer ID identity for distribution/notarization.
    codesign --force --deep --sign "${CASCADE_SIGN_IDENTITY:--}" "$APP" 2>&1 | grep -v "replacing existing signature" || true
    codesign --verify --deep --strict "$APP" && echo "==> code seal OK"
    echo "==> app: $APP"
    ;;
  *) echo "usage: $0 [run|build]"; exit 2 ;;
esac
