#!/usr/bin/env bash
# Build a Debian/Ubuntu package.
#
#   scripts/package-linux.sh [--cli-only] [--arch amd64|arm64]
#
# On Debian/Ubuntu it builds the full desktop package, dist/cascade_<ver>_<arch>.deb:
# the app (Flutter bundle + libcascade.so), the browser native host, the
# extension, an application-menu entry, autostart (hidden, tray only) and
# icons. Needs Go, gcc, and Flutter (the UI is built here if not already
# built). The postinst registers the native host system-wide for Chrome,
# Chromium and Edge; `cascade-register` does per-user registration for the
# other browsers and extra extension IDs.
#
# Anywhere else (or with --cli-only) it builds dist/cascade-cli_<ver>_<arch>.deb:
# the command-line downloader and the native host only, pure Go, no GUI
# (libcascade.so and the Flutter UI need a Linux build host).
#
# Upgrades: dpkg keeps settings and downloads; the same version reinstalls;
# an older package than the installed one is refused by the preinst unless
# CASCADE_FORCE=1. dpkg-deb is used when present, else the .deb is assembled
# with ar + tar (same result).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/go/bin:$PATH"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
. "$ROOT/scripts/lib/extension.sh"
. "$ROOT/scripts/lib/obfuscate.sh"
load_store_ids "$ROOT"
LDFLAGS="-s -w -X cascade/internal/version.Version=$VERSION"
DEB="$ROOT/packaging/debian"

CLI_ONLY=0; ARCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cli-only) CLI_ONLY=1 ;;
    --arch) ARCH="${2:-}"; shift ;;
    *) echo "usage: $0 [--cli-only] [--arch amd64|arm64]" >&2; exit 2 ;;
  esac
  shift
done
ON_LINUX=0; [ "$(uname -s)" = "Linux" ] && ON_LINUX=1
if [ "$ON_LINUX" = 0 ] && [ "$CLI_ONLY" = 0 ]; then
  echo "note: not on Linux, so building the CLI-only package (the desktop package needs a Linux build host)"
  CLI_ONLY=1
fi
if [ -z "$ARCH" ]; then
  if [ "$ON_LINUX" = 1 ] && command -v dpkg >/dev/null; then ARCH="$(dpkg --print-architecture)"; else ARCH=amd64; fi
fi
case "$ARCH" in
  amd64) GOARCH=amd64 ;;
  arm64) GOARCH=arm64 ;;
  *) echo "unsupported --arch $ARCH (amd64|arm64)" >&2; exit 2 ;;
esac

PKG=cascade; [ "$CLI_ONLY" = 1 ] && PKG=cascade-cli
STAGE="$ROOT/dist/deb-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/bin" "$STAGE/usr/lib/cascade" "$STAGE/usr/share/doc/$PKG"

echo "==> building $PKG $VERSION ($ARCH)"
(cd "$ROOT" && GOOS=linux GOARCH=$GOARCH CGO_ENABLED=0 go build -ldflags "$LDFLAGS" -o "$STAGE/usr/bin/cascade" ./cmd/cascade)
(cd "$ROOT" && GOOS=linux GOARCH=$GOARCH CGO_ENABLED=0 go build -ldflags "$LDFLAGS" -o "$STAGE/usr/lib/cascade/cascade-host" ./cmd/cascade-host)
echo "    usr/bin/cascade, usr/lib/cascade/cascade-host"

if [ "$CLI_ONLY" = 0 ]; then
  # Core as a shared library (cgo, native) and the Flutter bundle.
  (cd "$ROOT" && GOARCH=$GOARCH CGO_ENABLED=1 go build -ldflags "$LDFLAGS" -buildmode=c-shared -o "$STAGE/usr/lib/cascade/libcascade.so" ./export/cshared)
  BUNDLE="$(ls -d "$ROOT"/apps/flutter/build/linux/*/release/bundle 2>/dev/null | head -1 || true)"
  if [ -z "$BUNDLE" ]; then
    echo "    Flutter bundle not built; running flutter build linux"
    # CASCADE_OBFUSCATE=1: obfuscate Dart; symbol map stays outside the bundle.
    OBF_FLAGS=""
    if obf_on; then
      SYMDIR="$ROOT/dist/debug-symbols/linux-$VERSION"
      mkdir -p "$SYMDIR"
      OBF_FLAGS="--obfuscate --split-debug-info=$SYMDIR"
      echo "    Dart obfuscation on; symbol maps: $SYMDIR"
    fi
    # shellcheck disable=SC2086
    (cd "$ROOT/apps/flutter" && flutter build linux --release --build-name="$VERSION" --build-number=1 $OBF_FLAGS >/dev/null)
    BUNDLE="$(ls -d "$ROOT"/apps/flutter/build/linux/*/release/bundle | head -1)"
  fi
  cp -R "$BUNDLE" "$STAGE/usr/lib/cascade/cascade_app"
  cp "$STAGE/usr/lib/cascade/libcascade.so" "$STAGE/usr/lib/cascade/cascade_app/lib/libcascade.so"  # the Dart loader looks in <exe>/lib
  echo "    usr/lib/cascade/cascade_app (Flutter UI), libcascade.so"

  mkdir -p "$STAGE/usr/share/applications" "$STAGE/etc/xdg/autostart" "$STAGE/usr/share/cascade"
  cp "$DEB/cascade.desktop" "$STAGE/usr/share/applications/cascade.desktop"
  cp "$DEB/cascade-autostart.desktop" "$STAGE/etc/xdg/autostart/cascade.desktop"
  cp -R "$ROOT/browser/extension" "$STAGE/usr/share/cascade/extension"
  sed -e "s/@CHROME_WEBSTORE_ID@/${CHROME_WEBSTORE_ID:-}/g" -e "s/@EDGE_ADDONS_ID@/${EDGE_ADDONS_ID:-}/g" "$DEB/cascade-register" > "$STAGE/usr/bin/cascade-register"
  chmod 0755 "$STAGE/usr/bin/cascade-register"
  for s in 64 128 256 512; do
    d="$STAGE/usr/share/icons/hicolor/${s}x${s}/apps"; mkdir -p "$d"
    cp "$ROOT/assets/brand/linux/cascade-$s.png" "$d/cascade.png"
  done
  for f in preinst postinst prerm postrm; do
    sed -e "s/@VERSION@/$VERSION/g" -e "s/@CHROME_WEBSTORE_ID@/${CHROME_WEBSTORE_ID:-}/g" -e "s/@EDGE_ADDONS_ID@/${EDGE_ADDONS_ID:-}/g" \
      "$DEB/$f" > "$STAGE/DEBIAN/$f"; chmod 0755 "$STAGE/DEBIAN/$f"
  done
  DEPENDS="libc6, libgtk-3-0, libglib2.0-0"
  RECOMMENDS="libayatana-appindicator3-1, chromium | google-chrome-stable | microsoft-edge-stable"
  CONFLICTS="cascade-cli"
  DESC="Download manager: parallel connections, resume, queue, browser capture
 Cascade takes over downloads from the browser (Chrome, Chromium, Edge,
 Brave, Vivaldi via its extension), downloads with several connections,
 resumes broken transfers, files downloads by category or site, schedules
 them and limits speed by time of day. Runs hidden in the tray at login.
 This package also installs the cascade command-line downloader."
else
  DEPENDS="libc6"
  RECOMMENDS=""
  CONFLICTS="cascade"
  DESC="Command-line download manager: parallel connections and resume
 The cascade command downloads a file with several connections, resumes
 broken transfers, verifies checksums and limits speed. No GUI; the
 desktop application is in the cascade package."
fi

cat > "$STAGE/usr/share/doc/$PKG/README" <<TXT
Cascade $VERSION ($PKG)
Command line: cascade <url> [-o out] [-n 8] [-resume] [-limit 2M]
$( [ "$CLI_ONLY" = 0 ] && cat <<'GUI'
Desktop: "Cascade" in the application menu; starts hidden at login (tray).
Browser: load /usr/share/cascade/extension in chrome://extensions (Developer
mode -> Load unpacked). Chrome, Chromium and Edge are registered system-wide;
for Brave, Vivaldi or another extension ID run: cascade-register [ID]
GUI
)
Settings: ~/.config/cascade/settings.json. Remove: apt remove $PKG
TXT

SIZE_KB="$(du -sk "$STAGE" | cut -f1)"
{
  echo "Package: $PKG"
  echo "Version: $VERSION"
  echo "Architecture: $ARCH"
  echo "Maintainer: d3xt3r"
  echo "Section: net"
  echo "Priority: optional"
  echo "Installed-Size: $SIZE_KB"
  echo "Depends: $DEPENDS"
  [ -n "$RECOMMENDS" ] && echo "Recommends: $RECOMMENDS"
  echo "Conflicts: $CONFLICTS"
  echo "Replaces: $CONFLICTS"
  echo "Description: $DESC"
} > "$STAGE/DEBIAN/control"
chmod 0644 "$STAGE/DEBIAN/control"
find "$STAGE" -type d -exec chmod 0755 {} +

OUT="$ROOT/dist/${PKG}_${VERSION}_${ARCH}.deb"
rm -f "$OUT"
if command -v dpkg-deb >/dev/null; then
  echo "==> dpkg-deb"
  dpkg-deb --build --root-owner-group "$STAGE" "$OUT" >/dev/null
else
  # No dpkg here: assemble the archive by hand (ar with debian-binary,
  # control.tar.gz, data.tar.gz in that order, root-owned entries).
  echo "==> assembling with ar + tar (no dpkg-deb on this host)"
  TMP="$STAGE.build"; rm -rf "$TMP"; mkdir -p "$TMP/data"
  cp -R "$STAGE"/. "$TMP/data/"; rm -rf "$TMP/data/DEBIAN"
  if tar --version 2>/dev/null | grep -q GNU; then OWN=(--owner=0 --group=0 --numeric-owner); else OWN=(--uid 0 --gid 0 --uname root --gname root --numeric-owner); fi
  export COPYFILE_DISABLE=1
  (cd "$STAGE/DEBIAN" && tar "${OWN[@]}" -czf "$TMP/control.tar.gz" .)
  (cd "$TMP/data" && tar "${OWN[@]}" -czf "$TMP/data.tar.gz" .)
  printf '2.0\n' > "$TMP/debian-binary"
  # Write the ar container ourselves: macOS ar adds a symbol table (ranlib)
  # that dpkg rejects. Common ar format: 60-byte headers, members padded to
  # an even size.
  ar_member() {
    local name="$1" file="$2" size
    size="$(wc -c < "$file" | tr -d ' ')"
    printf '%-16s%-12s%-6s%-6s%-8s%-10s`\n' "$name" "$(date +%s)" 0 0 100644 "$size"
    cat "$file"
    [ $((size % 2)) -eq 1 ] && printf '\n'
    return 0
  }
  {
    printf '!<arch>\n'
    ar_member debian-binary "$TMP/debian-binary"
    ar_member control.tar.gz "$TMP/control.tar.gz"
    ar_member data.tar.gz "$TMP/data.tar.gz"
  } > "$OUT"
  rm -rf "$TMP"
fi
shasum -a 256 "$OUT" | tee "$OUT.sha256"
echo "==> $OUT"
echo "    install: sudo apt install ./$(basename "$OUT")   (or: sudo dpkg -i ...)"
rm -rf "$STAGE"
