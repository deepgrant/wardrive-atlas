import MapKit
import SwiftUI
import WardriveAtlasCore

struct HeatmapFrame: Sendable {
  let image: CGImage
  let rect: MKMapRect
  let presentationID: UUID
}

/// Retain the prior geographic raster during pan/zoom, but never across data changes.
@MainActor final class HeatmapState: ObservableObject {
  @Published private(set) var frame: HeatmapFrame?
  private var revision = 0
  private var work: Task<CGImage?, Error>?
  private(set) var completion: Task<Void, Never>?
  private let render: @Sendable ([MapPoint], MKMapRect) async throws -> CGImage?

  init(
    render: @escaping @Sendable ([MapPoint], MKMapRect) async throws -> CGImage? = {
      try Heatmap.image(points: $0, rect: $1)
    }
  ) {
    self.render = render
  }

  func clear() {
    revision += 1
    work?.cancel()
    completion?.cancel()
    work = nil
    frame = nil
  }

  func update(_ presentation: MapPresentation, rect: MKMapRect) {
    revision += 1
    let ticket = revision
    work?.cancel()
    completion?.cancel()
    if frame?.presentationID != presentation.id { frame = nil }
    let points = presentation.points
    let render = render
    let task = Task.detached { try await render(points, rect) }
    work = task
    completion = Task {
      let image = try? await task.value
      guard ticket == revision else { return }
      work = nil
      frame = image.map { HeatmapFrame(image: $0, rect: rect, presentationID: presentation.id) }
    }
  }
}
