// Tray icons from the master app icon.
//   template: the icon's silhouette (rounded square with the arrow cut out) in
//   black + alpha, for macOS menu bar template rendering.
//   color: the icon as is, for Linux/Windows panels.
// usage: swift spate-tray-icon.swift <master.png> <out-dir>
import AppKit
let args = CommandLine.arguments
let master = NSImage(contentsOfFile: args[1])!
let outDir = args[2]

func render(size: Int, template: Bool) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current!.imageInterpolation = .high
  // The master has a ~10% transparent margin; tighten to a 1px margin so the
  // glyph fills the slot like other menu bar icons.
  let inset = Double(size) * 0.02
  master.draw(in: NSRect(x: inset - Double(size) * 0.1, y: inset - Double(size) * 0.1,
                         width: Double(size) * 1.2 - 2 * inset, height: Double(size) * 1.2 - 2 * inset))
  NSGraphicsContext.restoreGraphicsState()
  if template {
    // Blue body -> black; white arrow -> transparent (alpha carries the shape).
    // Work on the raw premultiplied RGBA bytes: colorAt/setColor are not
    // reliable across colour spaces.
    let data = rep.bitmapData!
    let rowBytes = rep.bytesPerRow, spp = rep.samplesPerPixel
    for y in 0..<size { for x in 0..<size {
      let i = y * rowBytes + x * spp
      let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2]), a = Int(data[i + 3])
      let white = a > 0 && r * 100 > 85 * a && g * 100 > 85 * a && b * 100 > 85 * a
      data[i] = 0; data[i + 1] = 0; data[i + 2] = 0
      data[i + 3] = white ? 0 : UInt8(a)
    } }
  }
  return rep
}
func write(_ rep: NSBitmapImageRep, _ name: String) {
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outDir + "/" + name))
}
write(render(size: 22, template: true), "icon.png")
write(render(size: 44, template: true), "icon@2x.png")
write(render(size: 48, template: false), "icon-color.png")
