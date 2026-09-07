import Foundation
import MapKit
import WardriveAtlasCore

/// Accumulate into a fixed grid, then blur in two passes. Work is bounded by points + grid area.
enum Heatmap {
  static func image(points: [MapPoint], rect: MKMapRect, size: Int = 256) throws -> CGImage? {
    guard MapViewport.isValid(rect), size > 0, size <= 1024 else { return nil }
    var bins = Array(repeating: 0.0, count: size * size)
    for (index, p) in points.enumerated() {
      if index % 512 == 0 { try Task.checkCancellation() }
      guard p.latitude.isFinite, p.longitude.isFinite, p.rssi.isFinite,
        abs(p.latitude) <= 90, abs(p.longitude) <= 180
      else { continue }
      let mp = MKMapPoint(CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude))
      let pixelX = (mp.x - rect.minX) / rect.width * Double(size)
      let pixelY = (mp.y - rect.minY) / rect.height * Double(size)
      guard pixelX.isFinite, pixelY.isFinite,
        pixelX >= 0, pixelY >= 0, pixelX < Double(size), pixelY < Double(size)
      else { continue }
      let x = Int(pixelX)
      let y = Int(pixelY)
      bins[y * size + x] += min(1, max(0, (p.rssi + 100) / 70))
    }
    let radius = 8
    let kernel = (-8...8).map { exp(-Double($0 * $0) / 18) }
    var horizontal = bins
    var blurred = bins
    for y in 0..<size {
      try Task.checkCancellation()
      for x in 0..<size {
        var value = 0.0
        for dx in -radius...radius where x + dx >= 0 && x + dx < size {
          value += bins[y * size + x + dx] * kernel[dx + radius]
        }
        horizontal[y * size + x] = value
      }
    }
    for y in 0..<size {
      try Task.checkCancellation()
      for x in 0..<size {
        var value = 0.0
        for dy in -radius...radius where y + dy >= 0 && y + dy < size {
          value += horizontal[(y + dy) * size + x] * kernel[dy + radius]
        }
        blurred[y * size + x] = value
      }
    }
    let maxValue = max(1, blurred.max() ?? 1)
    let stops: [(Double, Double, Double)] = [
      (41, 83, 159), (111, 63, 176), (192, 45, 131), (228, 61, 48), (255, 176, 0),
    ]
    var pixels = Array(repeating: UInt8(0), count: size * size * 4)
    for i in blurred.indices {
      let value = min(1, blurred[i] / maxValue)
      let stop = min(3, Int(value * 4))
      let t = value * 4 - Double(stop)
      let a = stops[stop]
      let b = stops[stop + 1]
      let alpha = min(0.88, value * 2)
      pixels[i * 4] = UInt8((a.0 + (b.0 - a.0) * t) * alpha)
      pixels[i * 4 + 1] = UInt8((a.1 + (b.1 - a.1) * t) * alpha)
      pixels[i * 4 + 2] = UInt8((a.2 + (b.2 - a.2) * t) * alpha)
      pixels[i * 4 + 3] = UInt8(alpha * 255)
    }
    let data = Data(pixels) as CFData
    guard let provider = CGDataProvider(data: data) else { return nil }
    return CGImage(
      width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
  }
}
