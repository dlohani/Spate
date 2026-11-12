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
#
# Signing (all optional; without them the package is unsigned and Gatekeeper
# warns). These need an Apple Developer account:
#   SPATE_SIGN_IDENTITY       "Developer ID Application: ..." signs the app and
#                             the native host (also read by flutter-macos.sh)
#   SPATE_INSTALLER_IDENTITY  "Developer ID Installer: ..." signs the .pkg
#   SPATE_NOTARY_PROFILE      keychain profile saved with
#                             `xcrun notarytool store-credentials`; the signed
#                             .pkg is notarized and the ticket stapled
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

# is_universal FILE: true when it carries both Apple Silicon and Intel code.
# (One architecture is tested per call: this lipo rejects two in one.)
is_universal() { lipo "$1" -verify_arch arm64 && lipo "$1" -verify_arch x86_64; }

echo "==> building components"
cmd="$(go_build_cmd cli)"
# Universal (Apple Silicon + Intel), like the app: one host per architecture,
# joined with lipo.
for arch in arm64 amd64; do
  # shellcheck disable=SC2086
  (cd "$ROOT" && GOOS=darwin GOARCH="$arch" $cmd -ldflags "$LDFLAGS" -o "$STAGE/spate-host-$arch" ./cmd/spate-host)
done
lipo -create -output "$PAYLOAD/bin/spate-host" "$STAGE/spate-host-arm64" "$STAGE/spate-host-amd64"
rm -f "$STAGE/spate-host-arm64" "$STAGE/spate-host-amd64"
# Fail here, not on a user's Intel Mac, if the host lost an architecture.
is_universal "$PAYLOAD/bin/spate-host" || { echo "error: spate-host is not universal" >&2; exit 1; }
if [ -n "${SPATE_SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SPATE_SIGN_IDENTITY" "$PAYLOAD/bin/spate-host"
fi
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
is_universal "$APPROOT/Spate.app/Contents/Frameworks/libspate.dylib" \
  || { echo "error: libspate.dylib in the app is not universal; run scripts/flutter-macos.sh build" >&2; exit 1; }
if obf_on; then
  # A release must not ship a plain core by accident: check the pieces that
  # go into the package before it is built.
  # Each architecture slice is checked by itself: the symbol tools read one
  # architecture at a time, and a universal file would double the export count.
  for arch in arm64 x86_64; do
    mkdir -p "$STAGE/verify-$arch"
    lipo "$PAYLOAD/bin/spate-host" -thin "$arch" -output "$STAGE/verify-$arch/spate-host"
    lipo "$APPROOT/Spate.app/Contents/Frameworks/libspate.dylib" -thin "$arch" -output "$STAGE/verify-$arch/libspate.dylib"
    "$ROOT/scripts/verify-obfuscation.sh" "$STAGE/verify-$arch/spate-host" "$STAGE/verify-$arch/libspate.dylib"
    rm -rf "$STAGE/verify-$arch"
  done
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
if [ -n "${SPATE_INSTALLER_IDENTITY:-}" ]; then
  echo "==> signing the package"
  productsign --sign "$SPATE_INSTALLER_IDENTITY" "$OUT" "$OUT.signed" >/dev/null
  mv -f "$OUT.signed" "$OUT"
  if [ -n "${SPATE_NOTARY_PROFILE:-}" ]; then
    echo "==> notarizing (waits for Apple)"
    xcrun notarytool submit "$OUT" --keychain-profile "$SPATE_NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUT"
  fi
fi
shasum -a 256 "$OUT" | tee "$OUT.sha256"
echo "==> $OUT"
if [ -z "${SPATE_INSTALLER_IDENTITY:-}" ]; then
  echo "    unsigned: macOS blocks the first open; allow it under System Settings -> Privacy & Security -> Open Anyway,"
  echo "    or: installer -pkg \"$OUT\" -target CurrentUserHomeDirectory"
fi

# The staging tree contains a full app bundle; remove it so Spotlight cannot
# offer a stale copy of Spate from dist/.
rm -rf "$STAGE"
