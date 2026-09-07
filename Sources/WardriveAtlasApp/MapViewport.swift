import MapKit

enum MapViewport {
  static let minimumSpan = 256.0

  static func isValid(_ rect: MKMapRect) -> Bool {
    rect.origin.x.isFinite && rect.origin.y.isFinite
      && rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
      && rect.maxX.isFinite && rect.maxY.isFinite
  }

  static func constrained(_ rect: MKMapRect) -> MKMapRect {
    guard isValid(rect) else { return .world }
    let world = MKMapRect.world
    let width = min(world.width, max(minimumSpan, rect.width))
    let height = min(world.height, max(minimumSpan, rect.height))
    return MKMapRect(
      x: min(world.maxX - width, max(world.minX, rect.midX - width / 2)),
      y: min(world.maxY - height, max(world.minY, rect.midY - height / 2)),
      width: width, height: height)
  }

  static func zoom(_ rect: MKMapRect, by factor: Double) -> MKMapRect {
    let current = constrained(rect)
    guard factor.isFinite, factor > 0 else { return current }
    let width = min(MKMapRect.world.width, max(minimumSpan, current.width * factor))
    let height = min(MKMapRect.world.height, max(minimumSpan, current.height * factor))
    return constrained(
      MKMapRect(
        x: current.midX - width / 2, y: current.midY - height / 2, width: width, height: height))
  }

  /// A cached raster keeps its geographic extent while the viewport changes underneath it.
  static func screenRect(_ imageRect: MKMapRect, in viewport: MKMapRect, size: CGSize) -> CGRect {
    guard isValid(imageRect), isValid(viewport), size.width.isFinite, size.height.isFinite,
      size.width > 0, size.height > 0
    else { return .zero }
    return CGRect(
      x: (imageRect.minX - viewport.minX) / viewport.width * size.width,
      y: (imageRect.minY - viewport.minY) / viewport.height * size.height,
      width: imageRect.width / viewport.width * size.width,
      height: imageRect.height / viewport.height * size.height)
  }
}
