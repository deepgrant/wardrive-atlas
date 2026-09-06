import MapKit
import WardriveAtlasCore

/// Bound MapKit's annotation/view population while retaining exact visible observation counts.
struct DisplayAnnotation: Sendable {
  var point: MapPoint
  var count: Int = 1
  var bounds: MKMapRect?

  private struct Cell: Hashable {
    var x: Int
    var y: Int
    var kind: String
    var radio: Radio
  }
  static func visible(_ points: [MapPoint], in rect: MKMapRect, size: CGSize) throws -> [Self] {
    guard rect.width > 0, rect.height > 0, size.width > 0, size.height > 0 else { return [] }
    let aggregate = points.count > 1_500
    let columns = max(1, Int(sqrt(400 * size.width / size.height)))
    let rows = max(1, 400 / columns)
    var bins: [Cell: Self] = [:]
    var individuals: [Self] = []
    var visibleCount = 0
    for (index, point) in points.enumerated() {
      if index % 512 == 0 { try Task.checkCancellation() }
      let position = MKMapPoint(
        CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
      guard rect.contains(position) else { continue }
      visibleCount += 1
      let bounds = MKMapRect(origin: position, size: MKMapSize(width: 1, height: 1))
      if !aggregate {
        individuals.append(Self(point: point))
        continue
      }
      let cell = Cell(
        x: min(columns - 1, Int((position.x - rect.minX) / rect.width * Double(columns))),
        y: min(rows - 1, Int((position.y - rect.minY) / rect.height * Double(rows))),
        kind: point.kind, radio: point.radio)
      if var group = bins[cell] {
        group.count += 1
        group.bounds = group.bounds!.union(bounds)
        let center = MKMapPoint(x: group.bounds!.midX, y: group.bounds!.midY).coordinate
        group.point.latitude = center.latitude
        group.point.longitude = center.longitude
        group.point.selected = group.point.selected || point.selected
        group.point.weak = group.point.weak && point.weak
        bins[cell] = group
      } else {
        bins[cell] = Self(point: point, bounds: bounds)
      }
    }
    let result = aggregate ? Array(bins.values) : individuals
    assert(result.reduce(0) { $0 + $1.count } == visibleCount)
    return result
  }
}
