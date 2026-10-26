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

echo "==> master icon (Swift, SF Symbol arrow on a blue rounded square)"
cat > /tmp/spate-icon.swift <<'EOF'
import AppKit
let out = CommandLine.arguments[1]; let mode = CommandLine.arguments[2]   // full | flat | fg
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let top = NSColor(calibratedRed: 0.24, green: 0.45, blue: 0.96, alpha: 1)   // #3D73F5
let bottom = NSColor(calibratedRed: 0.11, green: 0.31, blue: 0.85, alpha: 1) // #1D4FD8
if mode != "fg" {
  let inset: CGFloat = mode == "flat" ? 0 : S * 0.10
  let r = NSRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
  let path = mode == "flat" ? NSBezierPath(rect: r) : NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
  NSGradient(starting: top, ending: bottom)!.draw(in: path, angle: -90)
}
let cfg = NSImage.SymbolConfiguration(pointSize: S * (mode == "fg" ? 0.34 : 0.42), weight: .bold)
let sym = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
let tinted = NSImage(size: sym.size, flipped: false) { rect in
  sym.draw(in: rect); NSColor.white.set(); rect.fill(using: .sourceAtop); return true }
let sz = tinted.size
tinted.draw(in: NSRect(x: (S - sz.width)/2, y: (S - sz.height)/2, width: sz.width, height: sz.height), from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
EOF
swift /tmp/spate-icon.swift "$BRAND/icon-1024.png" full
swift /tmp/spate-icon.swift "$BRAND/icon-flat-1024.png" flat
swift /tmp/spate-icon.swift "$BRAND/icon-fg-1024.png" fg

echo "==> browser extension icons"
mkdir -p "$ROOT/browser/extension/icons"
for s in 16 32 48 128; do sips -z $s $s "$BRAND/icon-1024.png" --out "$ROOT/browser/extension/icons/$s.png" >/dev/null; done

echo "==> tray / menu-bar icons (macOS template, Linux colour, Windows .ico)"

swift "$ROOT/scripts/tray-icon.swift" "$BRAND/icon-1024.png" "$ROOT/apps/flutter/assets/tray" 2>/dev/null
cp "$BRAND/spate.ico" "$ROOT/apps/flutter/assets/tray/icon.ico"

echo "==> Linux hicolor icons (.deb)"
mkdir -p "$BRAND/linux"
for s in 64 128 256 512; do sips -z $s $s "$BRAND/icon-1024.png" --out "$BRAND/linux/spate-$s.png" >/dev/null; done
/Library/Frameworks/Python.framework/Versions/3.14/bin/python3 - "$ROOT/browser/extension/manifest.json" <<'EOF'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
d["icons"]={s:f"icons/{s}.png" for s in ("16","32","48","128")}
d["action"]["default_icon"]={s:f"icons/{s}.png" for s in ("16","32","48","128")}
json.dump(d,open(p,"w"),indent=2); open(p,"a").write("\n"); print("manifest icons set")
EOF

echo "==> Windows .ico (16..256, PNG-in-ICO) + Go resource for the exe icon"
for s in 16 32 48 256; do sips -z $s $s "$BRAND/icon-flat-1024.png" --out "/tmp/spate-ico-$s.png" >/dev/null; done
/Library/Frameworks/Python.framework/Versions/3.14/bin/python3 - "$BRAND/spate.ico" <<'EOF'
import struct,sys
sizes=[16,32,48,256]; pngs=[open(f"/tmp/spate-ico-{s}.png","rb").read() for s in sizes]
out=bytearray(struct.pack("<HHH",0,1,len(sizes))); off=6+16*len(sizes)
for s,png in zip(sizes,pngs):
    out+=struct.pack("<BBBBHHII", s%256, s%256, 0, 0, 1, 32, len(png), off); off+=len(png)
for png in pngs: out+=png
open(sys.argv[1],"wb").write(out); print("ico:", len(out), "bytes")
EOF
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
  adaptive_icon_background: "#2563EB"
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
