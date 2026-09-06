// Legacy procedural icon, retained as an alternate design.
// The current application icon is prepared with: swift Scripts/prepare-app-icon.swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("Sources/WardriveAtlasApp/Resources/Assets.xcassets")
let directory = assets.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8)
  .write(to: assets.appendingPathComponent("Contents.json"))
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = size * scale
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = graphics
    graphics.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let tile = NSBezierPath(
      roundedRect: NSRect(x: 65, y: 65, width: 894, height: 894), xRadius: 194, yRadius: 194)
    NSGradient(
      starting: NSColor(red: 0.12, green: 0.19, blue: 0.32, alpha: 1),
      ending: NSColor(red: 0.27, green: 0.28, blue: 0.60, alpha: 1))!.draw(in: tile, angle: 70)
    graphics.cgContext.saveGState()
    tile.addClip()
    NSColor.white.withAlphaComponent(0.10).setStroke()
    for offset in stride(from: 180, through: 920, by: 148) {
      let grid = NSBezierPath()
      grid.move(to: NSPoint(x: offset, y: 64))
      grid.line(to: NSPoint(x: offset, y: 960))
      grid.move(to: NSPoint(x: 64, y: offset))
      grid.line(to: NSPoint(x: 960, y: offset))
      grid.lineWidth = 3
      grid.stroke()
    }
    let river = NSBezierPath()
    river.move(to: NSPoint(x: 200, y: 1050))
    river.curve(
      to: NSPoint(x: 660, y: -50), controlPoint1: NSPoint(x: 990, y: 700),
      controlPoint2: NSPoint(x: 120, y: 420))
    river.lineWidth = 76
    NSColor(red: 0.35, green: 0.65, blue: 0.77, alpha: 0.28).setStroke()
    river.stroke()
    let route = NSBezierPath()
    route.move(to: NSPoint(x: 290, y: 310))
    route.line(to: NSPoint(x: 470, y: 450))
    route.line(to: NSPoint(x: 400, y: 610))
    route.line(to: NSPoint(x: 695, y: 736))
    route.lineWidth = 42
    route.lineJoinStyle = .round
    route.lineCapStyle = .round
    NSColor(red: 0.99, green: 0.77, blue: 0.34, alpha: 1).setStroke()
    route.stroke()
    for point in [
      NSPoint(x: 290, y: 310), NSPoint(x: 470, y: 450), NSPoint(x: 400, y: 610),
      NSPoint(x: 695, y: 736),
    ] {
      NSColor.white.setFill()
      NSBezierPath(ovalIn: NSRect(x: point.x - 29, y: point.y - 29, width: 58, height: 58)).fill()
    }
    let ring = NSBezierPath(ovalIn: NSRect(x: 595, y: 636, width: 200, height: 200))
    ring.lineWidth = 10
    NSColor.white.withAlphaComponent(0.50).setStroke()
    ring.stroke()
    graphics.cgContext.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    let filename = "icon_\(size)x\(size)@\(scale)x.png"
    try bitmap.representation(using: .png, properties: [:])!.write(
      to: directory.appendingPathComponent(filename))
    images.append([
      "idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename,
    ])
  }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
  .write(to: directory.appendingPathComponent("Contents.json"))
