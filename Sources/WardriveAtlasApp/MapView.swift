import AppKit
import MapKit
import SwiftUI
import WardriveAtlasCore

func pointColor(_ point: MapPoint) -> NSColor {
  if point.selected { return .systemOrange }
  if point.kind == "movement" { return .systemOrange }
  if point.kind != "observation" { return .systemIndigo }
  return point.radio == .ble ? .systemPurple : .systemRed
}
final class AtlasAnnotation: NSObject, MKAnnotation {
  let point: MapPoint
  let count: Int
  let bounds: MKMapRect?
  var coordinate: CLLocationCoordinate2D {
    .init(latitude: point.latitude, longitude: point.longitude)
  }
  var title: String? {
    count > 1
      ? "\(count.formatted()) observations in this area"
      : point.kind == "observation" ? "Observation" : "Observed here"
  }
  init(_ point: MapPoint, count: Int = 1, bounds: MKMapRect? = nil) {
    self.point = point
    self.count = count
    self.bounds = bounds
  }
}
final class AtlasOverlay: NSObject, MKOverlay {
  let points: [MapPoint]
  let projected: [MKMapPoint]
  let image: CGImage?
  let boundingMapRect: MKMapRect
  var coordinate: CLLocationCoordinate2D {
    MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
  }
  init(points: [MapPoint], image: CGImage? = nil, rect: MKMapRect? = nil) {
    self.points = points
    self.projected = points.map {
      MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
    }
    self.image = image
    self.boundingMapRect =
      rect
      ?? projected.reduce(MKMapRect.null) {
        $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 1, height: 1)))
      }.insetBy(dx: -1000, dy: -1000)
  }
}
final class AtlasOverlayRenderer: MKOverlayRenderer {
  override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
    guard let overlay = overlay as? AtlasOverlay else { return }
    if let image = overlay.image {
      let area = rect(for: overlay.boundingMapRect)
      context.saveGState()
      context.translateBy(x: area.minX, y: area.maxY)
      context.scaleBy(x: 1, y: -1)
      context.draw(image, in: CGRect(origin: .zero, size: area.size))
      context.restoreGState()
      return
    }
    for (index, point) in overlay.points.enumerated() {
      let projected = overlay.projected[index]
      guard mapRect.insetBy(dx: -12 / zoomScale, dy: -12 / zoomScale).contains(projected) else {
        continue
      }
      let center = self.point(for: projected)
      let radius = (point.selected ? 5.5 : 3.2) / zoomScale
      context.setFillColor(pointColor(point).withAlphaComponent(0.85).cgColor)
      context.fillEllipse(
        in: CGRect(
          x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
  }
}

/// Accumulate into a fixed grid, then blur in two passes. Work is bounded by points + grid area.
enum Heatmap {
  static func image(points: [MapPoint], rect: MKMapRect, size: Int = 256) throws -> CGImage? {
    guard rect.width > 0, rect.height > 0 else { return nil }
    var bins = Array(repeating: 0.0, count: size * size)
    for (index, p) in points.enumerated() {
      if index % 512 == 0 { try Task.checkCancellation() }
      let mp = MKMapPoint(CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude))
      let x = Int((mp.x - rect.minX) / rect.width * Double(size))
      let y = Int((mp.y - rect.minY) / rect.height * Double(size))
      if x >= 0, y >= 0, x < size, y < size {
        bins[y * size + x] += min(1, max(0, (p.rssi + 100) / 70))
      }
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

struct NativeMapView: NSViewRepresentable {
  @EnvironmentObject var app: AppCoordinator
  func makeCoordinator() -> Coordinator { Coordinator(app: app) }
  func makeNSView(context: Context) -> MKMapView {
    let map = MKMapView()
    map.delegate = context.coordinator
    map.showsCompass = true
    map.showsScale = true
    map.showsZoomControls = true
    map.isRotateEnabled = false
    map.isPitchEnabled = false
    map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "marker")
    map.register(
      MKMarkerAnnotationView.self,
      forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
    map.setRegion(
      .init(
        center: .init(latitude: 42.36, longitude: -71.06),
        span: .init(latitudeDelta: 0.12, longitudeDelta: 0.16)), animated: false)
    let click = NSClickGestureRecognizer(
      target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
    map.addGestureRecognizer(click)
    context.coordinator.map = map
    #if DEBUG
      if ProcessInfo.processInfo.environment["ATLAS_MAP_FAILURE"] == "1" {
        DispatchQueue.main.async {
          context.coordinator.mapViewDidFailLoadingMap(
            map, withError: URLError(.notConnectedToInternet))
        }
      }
    #endif
    return map
  }
  func updateNSView(_ map: MKMapView, context: Context) {
    let coordinator = context.coordinator
    if coordinator.revision != app.presentationRevision || coordinator.mode != app.mapMode {
      coordinator.revision = app.presentationRevision
      coordinator.mode = app.mapMode
      coordinator.rebuild()
    }
    let selected = app.presentation.points.filter(\.selected)
    let expected = Set(app.selectedRecords.map(\.id))
    if coordinator.focus != app.selection, Set(selected.map(\.id)) == expected {
      coordinator.focus = app.selection
      if !selected.isEmpty {
        let bounds = selected.reduce(MKMapRect.null) {
          $0.union(
            MKMapRect(
              origin: MKMapPoint(
                CLLocationCoordinate2D(latitude: $1.latitude, longitude: $1.longitude)),
              size: MKMapSize(width: 1, height: 1)))
        }
        map.setVisibleMapRect(
          bounds.insetBy(dx: -max(1500, bounds.width * 0.15), dy: -max(1500, bounds.height * 0.15)),
          animated: true)
      }
    }
    if coordinator.fit != app.fitRevision
      || (coordinator.needsInitialFit && !app.presentation.points.isEmpty)
    {
      coordinator.fit = app.fitRevision
      coordinator.needsInitialFit = app.presentation.points.isEmpty
      let points = app.presentation.points
      let rect = points.reduce(MKMapRect.null) { result, point in
        result.union(
          MKMapRect(
            origin: MKMapPoint(
              CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)),
            size: MKMapSize(width: 1, height: 1)))
      }
      if !rect.isNull {
        map.setVisibleMapRect(
          rect.insetBy(dx: -max(1500, rect.width * 0.12), dy: -max(1500, rect.height * 0.12)),
          animated: true)
      }
    }
  }
  static func dismantleNSView(_ map: MKMapView, coordinator: Coordinator) {
    coordinator.annotationWork?.cancel()
    coordinator.annotationTask?.cancel()
    coordinator.heatWork?.cancel()
    coordinator.heatTask?.cancel()
    map.delegate = nil
    coordinator.map = nil
  }
  @MainActor final class Coordinator: NSObject, MKMapViewDelegate {
    let app: AppCoordinator
    weak var map: MKMapView?
    var revision = -1, fit = -1, needsInitialFit = true
    var mode: MapMode = .points
    var focus: Selection?
    var heatWork: Task<CGImage?, Error>?, heatTask: Task<Void, Never>?
    var annotationWork: Task<[DisplayAnnotation], Error>?
    var annotationTask: Task<Void, Never>?
    var annotationGeneration = 0
    var heatGeneration = 0
    init(app: AppCoordinator) { self.app = app }
    func rebuild() {
      guard let map else { return }
      heatGeneration += 1
      heatWork?.cancel()
      heatTask?.cancel()
      map.removeAnnotations(map.annotations)
      map.removeOverlays(map.overlays)
      let data = app.presentation
      scheduleAnnotations()
      if mode == .points, !data.points.isEmpty {
        map.addOverlay(AtlasOverlay(points: data.points))
      }
      for path in data.paths {
        var coords = path.coordinates.map {
          CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        let line = MKPolyline(coordinates: &coords, count: coords.count)
        line.title = path.movement ? "movement" : "route"
        map.addOverlay(line)
      }
      let selected = data.points.filter(\.selected)
      if !selected.isEmpty { map.addOverlay(AtlasOverlay(points: selected), level: .aboveLabels) }
      if mode == .heatmap { scheduleHeatmap() }
    }
    func scheduleAnnotations() {
      guard let map else { return }
      annotationGeneration += 1
      let ticket = annotationGeneration
      annotationWork?.cancel()
      annotationTask?.cancel()
      let data = app.presentation
      let points = mode == .clusters ? data.points : []
      let rect = map.visibleMapRect.insetBy(
        dx: -map.visibleMapRect.width * 0.15, dy: -map.visibleMapRect.height * 0.15)
      let size = map.bounds.size
      annotationTask = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        guard let self, ticket == self.annotationGeneration else { return }
        let work = Task.detached {
          try DisplayAnnotation.visible(points, in: rect, size: size)
            + DisplayAnnotation.visible(data.pins, in: rect, size: size)
        }
        self.annotationWork = work
        guard let annotations = try? await work.value, ticket == self.annotationGeneration,
          let map = self.map
        else { return }
        map.removeAnnotations(map.annotations)
        map.addAnnotations(
          annotations.map { AtlasAnnotation($0.point, count: $0.count, bounds: $0.bounds) })
      }
    }
    func scheduleHeatmap() {
      guard let map, mode == .heatmap else { return }
      heatGeneration += 1
      let ticket = heatGeneration
      heatWork?.cancel()
      heatTask?.cancel()
      let points = app.presentation.points
      let rect = map.visibleMapRect.insetBy(
        dx: -map.visibleMapRect.width * 0.1, dy: -map.visibleMapRect.height * 0.1)
      heatTask = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        guard let self, ticket == self.heatGeneration else { return }
        let work = Task.detached { try Heatmap.image(points: points, rect: rect) }
        self.heatWork = work
        guard let image = try? await work.value, ticket == self.heatGeneration, let map = self.map
        else { return }
        map.removeOverlays(map.overlays.filter { ($0 as? AtlasOverlay)?.image != nil })
        map.insertOverlay(
          AtlasOverlay(points: [], image: image, rect: rect), at: 0, level: .aboveRoads)
      }
    }
    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
      scheduleHeatmap()
      scheduleAnnotations()
    }
    func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) {
      app.mapStatus = "Street map unavailable · turn off Street map to use the offline grid"
    }
    func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
      #if DEBUG
        if ProcessInfo.processInfo.environment["ATLAS_MAP_FAILURE"] == "1" { return }
      #endif
      app.mapStatus = "Apple Maps · observations stay on this Mac"
    }
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
      if let line = overlay as? MKPolyline {
        let renderer = MKPolylineRenderer(polyline: line)
        renderer.strokeColor = line.title == "movement" ? .systemOrange : .systemIndigo
        renderer.lineWidth = 2.5
        if line.title == "movement" { renderer.lineDashPattern = [5, 4] }
        return renderer
      }
      return AtlasOverlayRenderer(overlay: overlay)
    }
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
      if let cluster = annotation as? MKClusterAnnotation {
        let view =
          mapView.dequeueReusableAnnotationView(
            withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier, for: cluster)
          as! MKMarkerAnnotationView
        view.markerTintColor = .systemIndigo
        view.glyphText = cluster.memberAnnotations.reduce(0) {
          $0 + (($1 as? AtlasAnnotation)?.count ?? 1)
        }.formatted()
        view.glyphImage = nil
        view.titleVisibility = .hidden
        return view
      }
      guard let item = annotation as? AtlasAnnotation else { return nil }
      let view =
        mapView.dequeueReusableAnnotationView(withIdentifier: "marker", for: item)
        as! MKMarkerAnnotationView
      view.clusteringIdentifier =
        item.point.kind == "observation" && mode == .clusters ? "observations" : nil
      view.markerTintColor = pointColor(item.point)
      view.glyphText = nil
      let symbol: String =
        switch item.point.kind {
        case "flock": "video.fill"
        case "axon": "camera.fill"
        case "meta": "eyeglasses"
        case "multiple": "plus"
        case "movement": "arrow.triangle.turn.up.right.diamond"
        default: item.point.radio == .ble ? "antenna.radiowaves.left.and.right" : "wifi"
        }
      if item.count > 1 {
        view.glyphText = item.count.formatted(.number.notation(.compactName))
        view.glyphImage = nil
      } else {
        view.glyphImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      }
      view.alphaValue = item.point.weak ? 0.62 : 1
      view.titleVisibility = .hidden
      view.canShowCallout = false
      view.displayPriority = item.point.kind == "observation" ? .defaultLow : .required
      return view
    }
    func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
      guard let annotation = view.annotation else { return }
      if let cluster = annotation as? MKClusterAnnotation {
        mapView.showAnnotations(cluster.memberAnnotations, animated: true)
      } else if let item = annotation as? AtlasAnnotation {
        if item.count > 1, let bounds = item.bounds, bounds.width > 1 || bounds.height > 1 {
          mapView.setVisibleMapRect(
            bounds.insetBy(dx: -max(1, bounds.width * 0.2), dy: -max(1, bounds.height * 0.2)),
            animated: true)
        } else {
          app.selectMap(item.point.id)
        }
      }
      mapView.deselectAnnotation(annotation, animated: false)
    }
    @objc func clicked(_ recognizer: NSClickGestureRecognizer) {
      guard let map, mode != .clusters else { return }
      let location = recognizer.location(in: map)
      for values in [app.presentation.pins, app.presentation.points] {
        var nearest: (String, CGFloat)?
        for p in values {
          let screen = map.convert(
            CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude), toPointTo: map)
          let distance = hypot(screen.x - location.x, screen.y - location.y)
          if distance < 16, distance < (nearest?.1 ?? .infinity) { nearest = (p.id, distance) }
        }
        if let nearest {
          app.selectMap(nearest.0)
          return
        }
      }
    }
  }
}
