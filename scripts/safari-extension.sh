#!/usr/bin/env bash
# Build the Safari web extension: Safari extensions ship inside a macOS app,
# so this wraps browser/extension (Safari manifest) with Xcode's converter,
# builds the wrapper app and installs it to ~/Applications.
#
#   scripts/safari-extension.sh            build + install "Spate for Safari.app"
#   scripts/safari-extension.sh project    only generate the Xcode project (dist/safari)
#
# Requires Xcode. Ad hoc signed: Safari then needs Develop -> "Allow Unsigned
# Extensions" (once per Safari launch) or a Developer ID signature for real
# distribution (set SPATE_SIGN_IDENTITY, plus notarization).
#
# Safari has no downloads API: capture there is the right-click "Download
# with Spate" on links and capture.js intercepting clicks on file links.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
MODE="${1:-build}"
SRC="$ROOT/dist/safari-extension"
OUT="$ROOT/dist/safari"
APPNAME="Spate for Safari"

"$ROOT/scripts/package-extension.sh" >/dev/null
rm -rf "$OUT"; mkdir -p "$OUT"
echo "==> generating Xcode project"
xcrun safari-web-extension-converter "$SRC" \
  --project-location "$OUT" --app-name "$APPNAME" \
  --bundle-identifier com.amlabs.spate.safari --macos-only --no-open --no-prompt --force >/dev/null
PROJ="$(ls -d "$OUT"/*/*.xcodeproj | head -1)"
# The converter derives the app's bundle id from the app name
# (com.amlabs.spate.Spate-for-Safari), which does not prefix the extension's
# id (com.amlabs.spate.safari.Extension) and fails the build; pin the app's
# id. Xcode 26 and earlier write project.pbxproj, Xcode 27 project.xcproj.
PROJFILE=""
for f in "$PROJ/project.pbxproj" "$PROJ/project.xcproj"; do [ -f "$f" ] && PROJFILE="$f" && break; done
[ -n "$PROJFILE" ] || { echo "error: no project file under $PROJ" >&2; exit 1; }
perl -pi -e 's/(PRODUCT_BUNDLE_IDENTIFIER\s*=\s*)"?[^";]*Spate-for-Safari"?;/${1}com.amlabs.spate.safari;/g' "$PROJFILE"
perl -pi -e 's/("PRODUCT_BUNDLE_IDENTIFIER"\s*:\s*)"[^"]*Spate-for-Safari"/$1"com.amlabs.spate.safari"/g' "$PROJFILE"
perl -pi -e 's/\b[\w\.]*Spate-for-Safari\b/com.amlabs.spate.safari/g' "$PROJFILE"
grep -q 'com\.amlabs\.spate\.safari' "$PROJFILE" && ! grep -q 'PRODUCT_BUNDLE_IDENTIFIER.*Spate-for-Safari' "$PROJFILE" \
  || { echo "error: could not pin the app bundle id in $PROJFILE" >&2; exit 1; }
echo "    $PROJ"
[ "$MODE" = "project" ] && exit 0

echo "==> building ($VERSION)"
xcodebuild -project "$PROJ" -scheme "$APPNAME" -configuration Release \
  -derivedDataPath "$OUT/build" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION=1 \
  CODE_SIGN_IDENTITY="${SPATE_SIGN_IDENTITY:--}" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  build 2>&1 | grep -E "error:|warning: .*deprecated|BUILD" | tail -5
APP="$(find "$OUT/build/Build/Products/Release" -maxdepth 1 -name "*.app" | head -1)"
[ -n "$APP" ] || { echo "error: build produced no app" >&2; exit 1; }
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$APPNAME.app"
cp -R "$APP" "$HOME/Applications/$APPNAME.app"
echo "==> installed: $HOME/Applications/$APPNAME.app"
echo "    Open it once, then Safari -> Settings -> Extensions -> enable Spate."
echo "    Ad hoc build: Safari -> Develop -> Allow Unsigned Extensions first (each Safari launch)."
open "$HOME/Applications/$APPNAME.app" || true
