// Tray icons: the macOS menu-bar template from the glyph SVG (black on
// transparent; macOS tints it for light and dark menu bars), and the colour
// icon from the master PNG for Linux and Windows panels.
// usage: swift tray-icon.swift <icon-1024.png> <glyph.svg> <out-dir>
import AppKit
let args = CommandLine.arguments
let master = NSImage(contentsOfFile: args[1])!
let glyph = NSImage(contentsOfFile: args[2])!
let outDir = args[3]

func render(_ img: NSImage, size: Int, inset: Double, alpha: Double = 1.0) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current!.imageInterpolation = .high
  let s = Double(size)
  img.draw(in: NSRect(x: inset * s, y: inset * s, width: s - 2 * inset * s, height: s - 2 * inset * s),
           from: .zero, operation: .sourceOver, fraction: alpha)
  NSGraphicsContext.restoreGraphicsState()
  return rep
}
func write(_ rep: NSBitmapImageRep, _ name: String) {
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outDir + "/" + name))
}
// Menu-bar slot is 22pt; the glyph fills it edge to edge like Apple's own.
write(render(glyph, size: 22, inset: 0.0), "icon.png")
write(render(glyph, size: 44, inset: 0.0), "icon@2x.png")
// Colour icon: the master has a 10% transparent margin; trim it for the panel.
write(render(master, size: 48, inset: -0.1), "icon-color.png")
// "Pulse" frames: the same at 40% opacity. While something downloads the app
// alternates them with the normal frames about once a second.
write(render(glyph, size: 22, inset: 0.0, alpha: 0.4), "icon-pulse.png")
write(render(glyph, size: 44, inset: 0.0, alpha: 0.4), "icon-pulse@2x.png")
write(render(master, size: 48, inset: -0.1, alpha: 0.4), "icon-color-pulse.png")
write(render(master, size: 256, inset: 0.0, alpha: 0.4), "icon-pulse-256.png")
