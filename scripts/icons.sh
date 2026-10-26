#!/usr/bin/env bash
# Generate every app icon from one source. Run on macOS (uses Swift + sips).
#
#   scripts/icons.sh
#
# Produces:
#   assets/brand/icon-1024.png      master (rounded square, transparent margin)
#   assets/brand/icon-flat-1024.png opaque full-bleed (iOS, favicon)
#   assets/brand/icon-fg-1024.png   glyph only (Android adaptive foreground)
#   assets/brand/spate.ico        multi-size Windows icon (exe, installer)
#   apps/flutter/{ios,android,macos,windows,linux}  via flutter_launcher_icons
#   apps/flutter/web/favicon.png + icons
#   browser/extension/icons/{16,32,48,128}.png (+ manifest "icons")
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:$PATH"
BRAND="$ROOT/assets/brand"; mkdir -p "$BRAND"

echo "==> master icons (rasterised from assets/brand/*.svg with AppKit)"
# icon.svg      rounded square with a transparent margin (macOS, Linux, extension)
# icon-flat.svg full-bleed square (iOS, Windows, favicon; the OS masks corners)
# icon-fg.svg   white glyph only (Android adaptive foreground)
# glyph.svg     black glyph (macOS menu-bar template, see tray-icon.swift)
cat > /tmp/spate-icon.swift <<'EOF2'
import AppKit
let svg = CommandLine.arguments[1], out = CommandLine.arguments[2]
let S = 1024
guard let img = NSImage(contentsOfFile: svg) else { fputs("cannot read \(svg)\n", stderr); exit(1) }
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current!.imageInterpolation = .high
img.draw(in: NSRect(x: 0, y: 0, width: S, height: S), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
EOF2
swift /tmp/spate-icon.swift "$BRAND/icon.svg"      "$BRAND/icon-1024.png"
swift /tmp/spate-icon.swift "$BRAND/icon-flat.svg" "$BRAND/icon-flat-1024.png"
swift /tmp/spate-icon.swift "$BRAND/icon-fg.svg"   "$BRAND/icon-fg-1024.png"

echo "==> browser extension icons"
mkdir -p "$ROOT/browser/extension/icons"
for s in 16 32 48 128; do sips -z $s $s "$BRAND/icon-1024.png" --out "$ROOT/browser/extension/icons/$s.png" >/dev/null; done

echo "==> tray / menu-bar icons (macOS template, Linux colour, Windows .ico)"

swift "$ROOT/scripts/tray-icon.swift" "$BRAND/icon-1024.png" "$BRAND/glyph.svg" "$ROOT/apps/flutter/assets/tray"

echo "==> Linux hicolor icons (.deb)"
mkdir -p "$BRAND/linux"
for s in 64 128 256 512; do sips -z $s $s "$BRAND/icon-1024.png" --out "$BRAND/linux/spate-$s.png" >/dev/null; done
python3 - "$ROOT/browser/extension/manifest.json" <<'EOF'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["icons"]={s:f"icons/{s}.png" for s in ("16","32","48","128")}
d["action"]["default_icon"]={s:f"icons/{s}.png" for s in ("16","32","48","128")}
json.dump(d,open(p,"w"),indent=2); open(p,"a").write("\n"); print("manifest icons set")
EOF

echo "==> Windows .ico (16..256, PNG-in-ICO) + Go resource for the exe icon"
for s in 16 32 48 256; do sips -z $s $s "$BRAND/icon-flat-1024.png" --out "/tmp/spate-ico-$s.png" >/dev/null; done
python3 - "$BRAND/spate.ico" <<'EOF'
import struct,sys
sizes=[16,32,48,256]; pngs=[open(f"/tmp/spate-ico-{s}.png","rb").read() for s in sizes]
out=bytearray(struct.pack("<HHH",0,1,len(sizes))); off=6+16*len(sizes)
for s,png in zip(sizes,pngs):
    out+=struct.pack("<BBBBHHII", s%256, s%256, 0, 0, 1, 32, len(png), off); off+=len(png)
for png in pngs: out+=png
open(sys.argv[1],"wb").write(out); print("ico:", len(out), "bytes")
EOF
cp "$BRAND/spate.ico" "$ROOT/apps/flutter/assets/tray/icon.ico"
echo "==> Flutter launcher icons (iOS, Android, macOS, Windows, Linux, web)"
cd "$ROOT/apps/flutter"
grep -q "flutter_launcher_icons" pubspec.yaml || flutter pub add --dev flutter_launcher_icons >/dev/null
cat > flutter_launcher_icons.yaml <<'EOF'
# One source for every platform icon; regenerate with scripts/icons.sh.
flutter_launcher_icons:
  image_path: "../../assets/brand/icon-1024.png"
  ios: true
  image_path_ios: "../../assets/brand/icon-flat-1024.png"
  remove_alpha_ios: true
  android: true
  adaptive_icon_background: "#2A5BEA"
  adaptive_icon_foreground: "../../assets/brand/icon-fg-1024.png"
  macos:
    generate: true
    image_path: "../../assets/brand/icon-1024.png"
  windows:
    generate: true
    image_path: "../../assets/brand/icon-flat-1024.png"
    icon_size: 256
  linux:
    generate: true
    image_path: "../../assets/brand/icon-1024.png"
EOF
dart run flutter_launcher_icons -f flutter_launcher_icons.yaml 2>&1 | grep -vE "^\s*$" | tail -12
echo "==> done"
