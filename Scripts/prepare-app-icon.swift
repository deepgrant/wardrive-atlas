// Prepare all macOS app icon sizes from the checked-in artwork; no generation service required.
// Run from the repository root: swift Scripts/prepare-app-icon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum IconError: Error {
  case invalidMaster
  case renderingFailed(Int)
  case encodingFailed(Int)
  case iconutilFailed(Int32)
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let master = root.appendingPathComponent("Artwork/WardriveAtlasIcon-v2.png")
guard let source = CGImageSourceCreateWithURL(master as CFURL, nil),
  let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
  original.width == original.height, original.width >= 1024,
  [.first, .last, .premultipliedFirst, .premultipliedLast].contains(original.alphaInfo)
else { throw IconError.invalidMaster }

let files = FileManager.default
let assets = root.appendingPathComponent(
  "Sources/WardriveAtlasApp/Resources/Assets.xcassets/AtlasAppIcon.appiconset")
try files.createDirectory(at: assets, withIntermediateDirectories: true)
let temporary = files.temporaryDirectory.appendingPathComponent("atlas-icon-\(UUID().uuidString)")
let iconset = temporary.appendingPathComponent("WardriveAtlas.iconset")
try files.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? files.removeItem(at: temporary) }

var images: [[String: String]] = []
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = size * scale
    guard let context = CGContext(
      data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw IconError.renderingFailed(pixels) }
    context.interpolationQuality = .high
    context.draw(original, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    guard let image = context.makeImage() else { throw IconError.renderingFailed(pixels) }
    let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data, UTType.png.identifier as CFString, 1, nil)
    else { throw IconError.encodingFailed(pixels) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw IconError.encodingFailed(pixels) }
    try (data as Data).write(to: assets.appendingPathComponent(filename), options: .atomic)
    try (data as Data).write(to: iconset.appendingPathComponent(filename), options: .atomic)
    images.append([
      "idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename,
    ])
  }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
  .write(to: assets.appendingPathComponent("Contents.json"), options: .atomic)

let icon = root.appendingPathComponent("Artwork/WardriveAtlas-v2.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", "--output", icon.path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { throw IconError.iconutilFailed(process.terminationStatus) }
print("Prepared 10 macOS icon representations (16–1024 pixels), preserving transparency.")
print("Asset catalog: \(assets.path)")
print("Standalone icon: \(icon.path)")
