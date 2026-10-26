#!/usr/bin/env bash
# Build the macOS installer package: dist/Spate-<version>.pkg
#
# Per-user .pkg (no admin password) built with Apple's pkgbuild/productbuild:
# Welcome -> Install -> Finish. Two components: the app into ~/Applications
# (preinstall stops a running instance), and the native host, browser
# extension and helper scripts into ~/Library/Application Support/spate
# (postinstall registers the browser host, adds the login item, starts the
# app). The Distribution refuses a downgrade and warns on a reinstall.
#
# Prereqs: scripts/flutter-macos.sh build (Flutter app) and Go for the rest.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/go/bin:$PATH"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
LDFLAGS="-X spate/internal/version.Version=$VERSION"
. "$ROOT/scripts/lib/obfuscate.sh"
export OBF_ROOT="$ROOT"
obf_require_garble   # SPATE_OBFUSCATE=1 without garble fails loud, never ships plain
STAGE="$ROOT/dist/pkg-stage"; APPROOT="$STAGE/app"; PAYLOAD="$STAGE/payload"; RES="$STAGE/resources"; PKGS="$STAGE/pkgs"
rm -rf "$STAGE"; mkdir -p "$APPROOT" "$PAYLOAD/bin" "$PAYLOAD/extension" "$RES" "$PKGS" "$STAGE/scripts-app" "$STAGE/scripts-support"

echo "==> building components"
cmd="$(go_build_cmd cli)"
# shellcheck disable=SC2086
(cd "$ROOT" && $cmd -ldflags "$LDFLAGS" -o "$PAYLOAD/bin/spate-host" ./cmd/spate-host)
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
cp -R "$APP" "$APPROOT/Spate.app"
if obf_on; then
  # A release must not ship a plain core by accident: check the pieces that
  # go into the package before it is built.
  "$ROOT/scripts/verify-obfuscation.sh" "$PAYLOAD/bin/spate-host" "$APPROOT/Spate.app/Contents/Frameworks/libspate.dylib"
fi
cp -R "$ROOT/browser/extension/." "$PAYLOAD/extension/"
cp "$ROOT/packaging/macos/bin/register-extension" "$ROOT/packaging/macos/bin/uninstall" "$PAYLOAD/bin/"
chmod +x "$PAYLOAD/bin/"* 2>/dev/null || true

echo "==> component packages"
sed "s/@VERSION@/$VERSION/g" "$ROOT/packaging/macos/scripts/preinstall" > "$STAGE/scripts-app/preinstall"
cp "$ROOT/packaging/macos/scripts/postinstall" "$STAGE/scripts-support/postinstall"
chmod +x "$STAGE/scripts-app/preinstall" "$STAGE/scripts-support/postinstall"
pkgbuild --root "$APPROOT" \
  --identifier com.amlabs.spate.app --version "$VERSION" \
  --install-location "Applications" \
  --scripts "$STAGE/scripts-app" \
  "$PKGS/spate-app.pkg" >/dev/null
pkgbuild --root "$PAYLOAD" \
  --identifier com.amlabs.spate --version "$VERSION" \
  --install-location "Library/Application Support/spate" \
  --scripts "$STAGE/scripts-support" \
  "$PKGS/spate-support.pkg" >/dev/null

echo "==> product archive (Welcome / Install / Finish)"
sed "s/@VERSION@/$VERSION/g" "$ROOT/packaging/macos/Distribution.xml" > "$STAGE/Distribution.xml"
cp "$ROOT/packaging/macos/welcome.txt" "$ROOT/packaging/macos/conclusion.txt" "$RES/"
OUT="$ROOT/dist/Spate-$VERSION.pkg"
productbuild --distribution "$STAGE/Distribution.xml" --package-path "$PKGS" --resources "$RES" "$OUT" >/dev/null
shasum -a 256 "$OUT" | tee "$OUT.sha256"
echo "==> $OUT"
echo "    unsigned: open with right-click -> Open, or: installer -pkg \"$OUT\" -target CurrentUserHomeDirectory"

# The staging tree contains a full app bundle; remove it so Spotlight cannot
# offer a stale copy of Spate from dist/.
rm -rf "$STAGE"
