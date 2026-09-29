#!/usr/bin/env bash
# Build the macOS installer package: dist/Cascade-<version>.pkg
#
# Per-user .pkg (no admin password) built with Apple's pkgbuild/productbuild:
# Welcome -> Install -> Finish. Installs the Flutter app, the Fyne fallback,
# the native host, the browser extension and helper scripts under
# ~/Library/Application Support/cascade, then the postinstall registers the
# browser host, adds the login item and starts the app.
#
# Prereqs: scripts/flutter-macos.sh build (Flutter app) and Go for the rest.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/go/bin:$PATH"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
STAGE="$ROOT/dist/pkg-stage"; PAYLOAD="$STAGE/payload"; RES="$STAGE/resources"; PKGS="$STAGE/pkgs"
rm -rf "$STAGE"; mkdir -p "$PAYLOAD/bin" "$PAYLOAD/extension" "$RES" "$PKGS"

echo "==> building components"
(cd "$ROOT" && go build -o "$PAYLOAD/bin/cascade-host" ./cmd/cascade-host)
(cd "$ROOT/apps/macapp" && go build -o "$PAYLOAD/bin/cascade-mac" . 2> >(grep -v "duplicate librar" >&2 || true))
APP="$(ls -d "$ROOT"/apps/flutter/build/macos/Build/Products/Release/*.app 2>/dev/null | head -1 || true)"
if [ -z "$APP" ]; then
  echo "    Flutter app not built; running scripts/flutter-macos.sh build"
  "$ROOT/scripts/flutter-macos.sh" build >/dev/null
  APP="$(ls -d "$ROOT"/apps/flutter/build/macos/Build/Products/Release/*.app | head -1)"
fi
cp -R "$APP" "$PAYLOAD/bin/Cascade.app"
cp -R "$ROOT/browser/extension/." "$PAYLOAD/extension/"
cp "$ROOT/packaging/macos/bin/register-extension" "$ROOT/packaging/macos/bin/uninstall" "$PAYLOAD/bin/"
chmod +x "$PAYLOAD/bin/"* 2>/dev/null || true

echo "==> component package"
mkdir -p "$STAGE/scripts"; cp "$ROOT/packaging/macos/scripts/postinstall" "$STAGE/scripts/postinstall"; chmod +x "$STAGE/scripts/postinstall"
pkgbuild --root "$PAYLOAD" \
  --identifier dev.d3xt3r.cascade --version "$VERSION" \
  --install-location "Library/Application Support/cascade" \
  --scripts "$STAGE/scripts" \
  "$PKGS/cascade.pkg" >/dev/null

echo "==> product archive (Welcome / Install / Finish)"
sed "s/@VERSION@/$VERSION/" "$ROOT/packaging/macos/Distribution.xml" > "$STAGE/Distribution.xml"
cp "$ROOT/packaging/macos/welcome.txt" "$ROOT/packaging/macos/conclusion.txt" "$RES/"
OUT="$ROOT/dist/Cascade-$VERSION.pkg"
productbuild --distribution "$STAGE/Distribution.xml" --package-path "$PKGS" --resources "$RES" "$OUT" >/dev/null
shasum -a 256 "$OUT" | tee "$OUT.sha256"
echo "==> $OUT"
echo "    unsigned: open with right-click -> Open, or: installer -pkg \"$OUT\" -target CurrentUserHomeDirectory"
