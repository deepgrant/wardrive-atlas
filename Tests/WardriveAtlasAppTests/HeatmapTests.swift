import MapKit
import WardriveAtlasCore
import XCTest

@testable import WardriveAtlas

@MainActor final class HeatmapTests: XCTestCase {
  private func sample() -> MapPoint {
    MapPoint(id: "opaque", latitude: 42.35, longitude: -71.08, rssi: -50, radio: .ble)
  }
  func testViewportRemainsFiniteAndBoundedAfterRepeatedZoomAndPan() {
    var rect = MKMapRect(x: 81_000_000, y: 98_000_000, width: 120_000, height: 100_000)
    for _ in 0..<100 { rect = MapViewport.zoom(rect, by: 0.5) }
    XCTAssertEqual(rect.width, MapViewport.minimumSpan)
    XCTAssertEqual(rect.height, MapViewport.minimumSpan)
    for _ in 0..<100 { rect = MapViewport.zoom(rect, by: 2) }
    XCTAssertEqual(
      [rect.minX, rect.minY, rect.width, rect.height],
      [0, 0, MKMapRect.world.width, MKMapRect.world.height])
    for invalid in [
      MKMapRect.null, MKMapRect(x: .nan, y: 0, width: 1, height: 1),
      MKMapRect(x: 0, y: 0, width: .infinity, height: 1),
    ] {
      let valid = MapViewport.constrained(invalid)
      XCTAssertEqual(
        [valid.minX, valid.minY, valid.width, valid.height],
        [0, 0, MKMapRect.world.width, MKMapRect.world.height])
    }
    let panned = MapViewport.constrained(MKMapRect(x: -1_000, y: -2_000, width: 500, height: 500))
    XCTAssertEqual(panned.minX, 0)
    XCTAssertEqual(panned.minY, 0)
  }
  func testExtremeProjectionAndOutsidePointsNeverTrapOrPaint() throws {
    let center = MKMapPoint(CLLocationCoordinate2D(latitude: 42.36, longitude: -71.06))
    let width = 120_000 * pow(0.5, 60.0)
    let rect = MKMapRect(x: center.x, y: center.y, width: width, height: width)
    let image = try XCTUnwrap(Heatmap.image(points: [sample()], rect: rect))
    let data = try XCTUnwrap(image.dataProvider?.data) as Data
    XCTAssertTrue(data.allSatisfy { $0 == 0 })
    XCTAssertNil(try Heatmap.image(points: [sample()], rect: .null))
    XCTAssertNil(try Heatmap.image(points: [], rect: .world, size: 0))
    var invalid = sample()
    invalid.latitude = .nan
    invalid.rssi = .infinity
    let empty = try XCTUnwrap(Heatmap.image(points: [invalid], rect: .world))
    XCTAssertTrue((empty.dataProvider!.data! as Data).allSatisfy { $0 == 0 })
    // A point just outside the left boundary must not truncate into bin zero.
    let position = MKMapPoint(
      CLLocationCoordinate2D(latitude: sample().latitude, longitude: sample().longitude))
    let edge = MKMapRect(x: position.x + 0.01, y: position.y - 500, width: 1_000, height: 1_000)
    let outside = try XCTUnwrap(Heatmap.image(points: [sample()], rect: edge))
    XCTAssertTrue((outside.dataProvider!.data! as Data).allSatisfy { $0 == 0 })
  }
  func testFrameTracksGeographyDuringPanAndZoom() {
    let extent = MKMapRect(x: 1_000, y: 2_000, width: 1_000, height: 1_000)
    let panned = MKMapRect(x: 1_100, y: 2_200, width: 1_000, height: 1_000)
    let size = CGSize(width: 1_000, height: 500)
    XCTAssertEqual(
      MapViewport.screenRect(extent, in: panned, size: size),
      CGRect(x: -100, y: -100, width: 1_000, height: 500))
    let zoomed = MKMapRect(x: 1_250, y: 2_250, width: 500, height: 500)
    XCTAssertEqual(
      MapViewport.screenRect(extent, in: zoomed, size: size),
      CGRect(x: -500, y: -250, width: 2_000, height: 1_000))
    XCTAssertEqual(MapViewport.screenRect(extent, in: .null, size: size), .zero)
    XCTAssertEqual(
      MapViewport.screenRect(
        extent, in: zoomed, size: CGSize(width: CGFloat.infinity, height: 500)), .zero)
  }
  func testStaleFramesCannotReplaceNewDataOrSurviveClear() async throws {
    let gate = WorkGate<MKMapRect, CGImage?> { try Heatmap.image(points: [], rect: $0) }
    let state = HeatmapState(render: { _, rect in try await gate.submit(rect) })
    let first = MapPresentation()
    state.update(first, rect: .world)
    await gate.waitForArrival(1)
    let old = state.completion
    let second = MapPresentation()
    state.update(second, rect: .world)
    await gate.waitForArrival(2)
    await gate.release(2)
    await state.completion?.value
    XCTAssertEqual(state.frame?.presentationID, second.id)
    await gate.release(1)
    await old?.value
    XCTAssertEqual(state.frame?.presentationID, second.id)
    state.update(second, rect: MapViewport.zoom(.world, by: 0.5))
    XCTAssertEqual(
      state.frame?.presentationID, second.id, "Pan/zoom retains a geographically placed frame")
    await gate.waitForArrival(3)
    let pending = state.completion
    state.clear()
    await gate.release(3)
    await pending?.value
    XCTAssertNil(state.frame)
    state.update(first, rect: .world)
    await gate.waitForArrival(4)
    await gate.release(4)
    await state.completion?.value
    state.update(second, rect: .world)
    XCTAssertNil(state.frame, "Changed captures invalidate old density immediately")
    await gate.waitForArrival(5)
    await gate.release(5)
    await state.completion?.value
  }
}
