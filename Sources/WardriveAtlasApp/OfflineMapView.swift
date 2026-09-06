import MapKit
import SwiftUI
import WardriveAtlasCore

struct OfflineMapView: View {
  @EnvironmentObject var app: AppCoordinator
  @State private var rect = MKMapRect(x: 81_000_000, y: 98_000_000, width: 120_000, height: 100_000)
  @State private var dragStart: MKMapRect?
  @State private var fitted = false
  @State private var focus: Selection?
  @State private var heatImage: CGImage?
  @State private var heatTask: Task<CGImage?, Error>?
  @State private var heatRevision = 0
  var body: some View {
    GeometryReader { geometry in
      Canvas(rendersAsynchronously: true) { context, size in
        context.fill(
          Path(CGRect(origin: .zero, size: size)),
          with: .color(Color(red: 0.86, green: 0.9, blue: 0.88)))
        func screen(_ p: MapPoint) -> CGPoint {
          let mp = MKMapPoint(CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude))
          return CGPoint(
            x: (mp.x - rect.minX) / rect.width * size.width,
            y: (mp.y - rect.minY) / rect.height * size.height)
        }
        for i in 0...8 {
          let x = Double(i) * size.width / 8
          let y = Double(i) * size.height / 8
          var grid = Path()
          grid.move(to: .init(x: x, y: 0))
          grid.addLine(to: .init(x: x, y: size.height))
          grid.move(to: .init(x: 0, y: y))
          grid.addLine(to: .init(x: size.width, y: y))
          context.stroke(grid, with: .color(.black.opacity(0.1)), lineWidth: 1)
          if i < 8 {
            let coord = MKMapPoint(
              x: rect.minX + Double(i) * rect.width / 8, y: rect.minY + Double(i) * rect.height / 8
            ).coordinate
            context.draw(
              Text(String(format: "%.4f°", coord.longitude)).font(
                .system(size: 10, design: .monospaced)
              ).foregroundColor(.black.opacity(0.5)), at: CGPoint(x: x + 5, y: 8),
              anchor: .topLeading)
            context.draw(
              Text(String(format: "%.4f°", coord.latitude)).font(
                .system(size: 10, design: .monospaced)
              ).foregroundColor(.black.opacity(0.5)), at: CGPoint(x: 5, y: y + 25),
              anchor: .topLeading)
          }
        }
        if app.mapMode == .heatmap, let heatImage {
          context.draw(
            Image(decorative: heatImage, scale: 1), in: CGRect(origin: .zero, size: size))
        }
        for route in app.presentation.paths {
          var path = Path()
          for (i, p) in route.coordinates.enumerated() {
            if i == 0 { path.move(to: screen(p)) } else { path.addLine(to: screen(p)) }
          }
          context.stroke(
            path, with: .color(route.movement ? .orange : .indigo),
            style: StrokeStyle(lineWidth: 2, dash: route.movement ? [5, 4] : []))
        }
        if app.mapMode == .clusters {
          var clusters: [String: (CGPoint, Int)] = [:]
          for p in app.presentation.points {
            let s = screen(p)
            guard s.x >= 0, s.y >= 0, s.x < size.width, s.y < size.height else { continue }
            let key = "\(Int(s.x / 42)):\(Int(s.y / 42))"
            let old = clusters[key] ?? (.zero, 0)
            clusters[key] = (CGPoint(x: old.0.x + s.x, y: old.0.y + s.y), old.1 + 1)
          }
          for (_, group) in clusters {
            let center = CGPoint(x: group.0.x / Double(group.1), y: group.0.y / Double(group.1))
            context.fill(
              Path(ellipseIn: CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28)),
              with: .color(.indigo))
            context.draw(
              Text(group.1.formatted()).font(.system(size: 10, weight: .bold)).foregroundColor(
                .white), at: center)
          }
        }
        for p in app.presentation.points where app.mapMode == .points || p.selected {
          let s = screen(p)
          guard s.x >= -10, s.y >= -10, s.x <= size.width + 10, s.y <= size.height + 10 else {
            continue
          }
          let radius: Double = p.selected ? 6 : 3
          context.fill(
            Path(
              ellipseIn: CGRect(
                x: s.x - radius, y: s.y - radius, width: radius * 2, height: radius * 2)),
            with: .color(Color(nsColor: pointColor(p))))
        }
        for p in app.presentation.pins {
          let s = screen(p)
          let box = CGRect(x: s.x - 9, y: s.y - 9, width: 18, height: 18)
          let path = Path(ellipseIn: box)
          context.fill(path, with: .color(p.weak ? .white : Color(nsColor: pointColor(p))))
          context.stroke(
            path, with: .color(Color(nsColor: pointColor(p))),
            style: StrokeStyle(lineWidth: 2, dash: p.weak ? [3, 2] : []))
          let symbol =
            p.kind == "movement"
            ? "arrow.up.right"
            : p.kind == "meta"
              ? "eyeglasses"
              : p.kind == "flock" ? "video.fill" : p.kind == "axon" ? "camera.fill" : "plus"
          var resolved = context.resolve(Image(systemName: symbol))
          resolved.shading = .color(p.weak ? .indigo : .white)
          context.draw(resolved, at: s)
        }
      }
      .accessibilityLabel("Offline coordinate grid")
      .gesture(
        DragGesture(minimumDistance: 3).onChanged { value in
          if dragStart == nil { dragStart = rect }
          guard let start = dragStart else { return }
          rect = MKMapRect(
            x: start.minX - value.translation.width / geometry.size.width * start.width,
            y: start.minY - value.translation.height / geometry.size.height * start.height,
            width: start.width, height: start.height)
        }.onEnded { _ in
          dragStart = nil
          updateHeat()
        }
      )
      .simultaneousGesture(
        SpatialTapGesture().onEnded { value in
          for points in [app.presentation.pins, app.presentation.points] {
            let nearest = points.map { p -> (MapPoint, Double) in
              let mp = MKMapPoint(
                CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude))
              return (
                p,
                hypot(
                  (mp.x - rect.minX) / rect.width * geometry.size.width - value.location.x,
                  (mp.y - rect.minY) / rect.height * geometry.size.height - value.location.y)
              )
            }.filter { $0.1 < 20 }.min { $0.1 < $1.1 }
            if let nearest {
              app.selectMap(nearest.0.id)
              return
            }
          }
        }
      )
      .overlay(alignment: .topTrailing) {
        VStack {
          Button {
            zoom(0.5)
          } label: {
            Image(systemName: "plus")
          }.help("Zoom in")
          Button {
            zoom(2)
          } label: {
            Image(systemName: "minus")
          }.help("Zoom out")
        }.padding().buttonStyle(.borderedProminent).tint(.indigo)
      }
      .onAppear { fit() }
      .onChange(of: app.fitRevision) { fit() }
      .onChange(of: app.presentationRevision) {
        if !fitted { fit() }
        if focus != app.selection,
          Set(app.presentation.points.filter(\.selected).map(\.id))
            == Set(app.selectedRecords.map(\.id))
        {
          focus = app.selection
          if app.selection != nil { fit(selected: true) }
        }
        updateHeat()
      }
      .onChange(of: app.mapMode) { updateHeat() }
      .onDisappear {
        heatTask?.cancel()
        heatRevision += 1
      }
    }
  }
  private func zoom(_ factor: Double) {
    rect = MKMapRect(
      x: rect.midX - rect.width * factor / 2, y: rect.midY - rect.height * factor / 2,
      width: rect.width * factor, height: rect.height * factor)
    updateHeat()
  }
  private func fit(selected: Bool = false) {
    let points = selected ? app.presentation.points.filter(\.selected) : app.presentation.points
    let bounds = points.reduce(MKMapRect.null) {
      $0.union(
        MKMapRect(
          origin: MKMapPoint(
            CLLocationCoordinate2D(latitude: $1.latitude, longitude: $1.longitude)),
          size: MKMapSize(width: 1, height: 1)))
    }
    guard !bounds.isNull else { return }
    rect = bounds.insetBy(dx: -max(1500, bounds.width * 0.12), dy: -max(1500, bounds.height * 0.12))
    fitted = true
    updateHeat()
  }
  private func updateHeat() {
    heatRevision += 1
    let ticket = heatRevision
    heatTask?.cancel()
    guard app.mapMode == .heatmap else {
      heatImage = nil
      return
    }
    let points = app.presentation.points
    let bounds = rect
    let work = Task.detached { try Heatmap.image(points: points, rect: bounds) }
    heatTask = work
    Task {
      let image = try? await work.value
      if ticket == heatRevision { heatImage = image }
    }
  }
}
