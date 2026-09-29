#!/usr/bin/env bash
# Build the macOS installer package: dist/Cascade-<version>.pkg
#
# Per-user .pkg (no admin password) built with Apple's pkgbuild/productbuild:
# Welcome -> Install -> Finish. Two components: the app into ~/Applications
# (preinstall stops a running instance), and the native host, browser
# extension and helper scripts into ~/Library/Application Support/cascade
# (postinstall registers the browser host, adds the login item, starts the
# app). The Distribution refuses a downgrade and warns on a reinstall.
#
# Prereqs: scripts/flutter-macos.sh build (Flutter app) and Go for the rest.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/go/bin:$PATH"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
LDFLAGS="-X cascade/internal/version.Version=$VERSION"
STAGE="$ROOT/dist/pkg-stage"; APPROOT="$STAGE/app"; PAYLOAD="$STAGE/payload"; RES="$STAGE/resources"; PKGS="$STAGE/pkgs"
rm -rf "$STAGE"; mkdir -p "$APPROOT" "$PAYLOAD/bin" "$PAYLOAD/extension" "$RES" "$PKGS" "$STAGE/scripts-app" "$STAGE/scripts-support"

echo "==> building components"
(cd "$ROOT" && go build -ldflags "$LDFLAGS" -o "$PAYLOAD/bin/cascade-host" ./cmd/cascade-host)
APP="$(ls -d "$ROOT"/apps/flutter/build/macos/Build/Products/Release/*.app 2>/dev/null | head -1 || true)"
if [ -z "$APP" ]; then
  echo "    Flutter app not built; running scripts/flutter-macos.sh build"
  "$ROOT/scripts/flutter-macos.sh" build >/dev/null
  APP="$(ls -d "$ROOT"/apps/flutter/build/macos/Build/Products/Release/*.app | head -1)"
fi
BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ "$BUILT" != "$VERSION" ]; then
  echo "error: app bundle is version $BUILT but VERSION is $VERSION; run scripts/flutter-macos.sh build" >&2
  exit 1
fi
cp -R "$APP" "$APPROOT/Cascade.app"
cp -R "$ROOT/browser/extension/." "$PAYLOAD/extension/"
cp "$ROOT/packaging/macos/bin/register-extension" "$ROOT/packaging/macos/bin/uninstall" "$PAYLOAD/bin/"
chmod +x "$PAYLOAD/bin/"* 2>/dev/null || true

echo "==> component packages"
sed "s/@VERSION@/$VERSION/g" "$ROOT/packaging/macos/scripts/preinstall" > "$STAGE/scripts-app/preinstall"
cp "$ROOT/packaging/macos/scripts/postinstall" "$STAGE/scripts-support/postinstall"
chmod +x "$STAGE/scripts-app/preinstall" "$STAGE/scripts-support/postinstall"
pkgbuild --root "$APPROOT" \
  --identifier dev.d3xt3r.cascade.app --version "$VERSION" \
  --install-location "Applications" \
  --scripts "$STAGE/scripts-app" \
  "$PKGS/cascade-app.pkg" >/dev/null
pkgbuild --root "$PAYLOAD" \
  --identifier dev.d3xt3r.cascade --version "$VERSION" \
  --install-location "Library/Application Support/cascade" \
  --scripts "$STAGE/scripts-support" \
  "$PKGS/cascade-support.pkg" >/dev/null

echo "==> product archive (Welcome / Install / Finish)"
sed "s/@VERSION@/$VERSION/g" "$ROOT/packaging/macos/Distribution.xml" > "$STAGE/Distribution.xml"
cp "$ROOT/packaging/macos/welcome.txt" "$ROOT/packaging/macos/conclusion.txt" "$RES/"
OUT="$ROOT/dist/Cascade-$VERSION.pkg"
productbuild --distribution "$STAGE/Distribution.xml" --package-path "$PKGS" --resources "$RES" "$OUT" >/dev/null
shasum -a 256 "$OUT" | tee "$OUT.sha256"
echo "==> $OUT"
echo "    unsigned: open with right-click -> Open, or: installer -pkg \"$OUT\" -target CurrentUserHomeDirectory"

# The staging tree contains a full app bundle; remove it so Spotlight cannot
# offer a stale copy of Cascade from dist/.
rm -rf "$STAGE"
