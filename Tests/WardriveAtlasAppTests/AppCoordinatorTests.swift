import Foundation
import WardriveAtlasCore
import XCTest

@testable import WardriveAtlas

/// Deliberately completes cancelled work: generation checks must protect the application anyway.
actor WorkGate<Input: Sendable, Output: Sendable> {
  private var count = 0
  private var pending: [Int: (Output, CheckedContinuation<Output, Never>)] = [:]
  private var arrivals: [(Int, CheckedContinuation<Void, Never>)] = []
  private let process: @Sendable (Input) throws -> Output
  init(_ process: @escaping @Sendable (Input) throws -> Output) { self.process = process }
  func submit(_ input: Input) async throws -> Output {
    let output = try process(input)
    count += 1
    let index = count
    return await withCheckedContinuation { continuation in
      pending[index] = (output, continuation)
      let ready = arrivals.filter { $0.0 <= count }
      arrivals.removeAll { $0.0 <= count }
      for (_, arrival) in ready { arrival.resume() }
    }
  }
  func waitForArrival(_ index: Int) async {
    if count >= index { return }
    await withCheckedContinuation { arrivals.append((index, $0)) }
  }
  func release(_ index: Int) {
    guard let (output, continuation) = pending.removeValue(forKey: index) else {
      preconditionFailure("No pending work at index \(index)")
    }
    continuation.resume(returning: output)
  }
}

@MainActor final class AppCoordinatorTests: XCTestCase {
  private var directory: URL!
  override func setUp() {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "atlas-app-tests-\(UUID().uuidString)")
  }
  override func tearDown() { try? FileManager.default.removeItem(at: directory) }
  private func app() -> AppCoordinator {
    AppCoordinator(store: SettingsStore(directory: directory), debounce: .zero)
  }
  private func records() -> [Observation] {
    [
      Observation(
        id: "opaque-a", session: "A", bssid: "DA1020304050", ssid: "Ray-Ban A", latitude: 42,
        longitude: -71),
      Observation(
        id: "opaque-b", session: "B", bssid: "DA1020304051", ssid: "Ray-Ban B", latitude: 43,
        longitude: -72),
    ]
  }
  private func settle(_ app: AppCoordinator) async {
    await app.analysisTask?.value
    await app.projectionTask?.value
  }

  func testSelectionsRejectFilteredRemovedAndClearedPresentations() async throws {
    let app = app()
    await app.start()
    app.records = records()
    app.afterImport()
    await settle(app)
    let old = app.presentation.token(for: try XCTUnwrap(app.presentation.pins.first).id)
    app.filter.sessions = ["B"]
    app.selectMap(old)
    XCTAssertNil(app.selection)
    await settle(app)
    app.selectMap(old)
    XCTAssertNil(app.selection, "A marker cannot be reassigned to B when result IDs are reused")
    let current = app.presentation.token(for: try XCTUnwrap(app.presentation.pins.first).id)
    app.selectMap(current)
    XCTAssertEqual(app.selectedRecord?.ssid, "Ray-Ban B")
    XCTAssertEqual(app.selectedRecord?.identity, records()[1].identity)
    await app.projectionTask?.value
    let observation = app.presentation.token(for: "opaque-b")
    app.selectMap(observation)
    XCTAssertEqual(app.selectedRecord?.id, "opaque-b")
    app.removeSession("B")
    await settle(app)
    app.selectMap(current)
    XCTAssertNil(app.selection)
    app.clear()
    await settle(app)
    app.selectMap(observation)
    XCTAssertNil(app.selection)
    XCTAssertTrue(app.presentation.points.isEmpty)
  }

  func testCurrentMovementTokenResolvesItsOwnIdentity() async throws {
    let app = app()
    await app.start()
    app.analysisPanel = "Co-travel"
    let rows = (0..<3).map { index in
      Observation(
        id: "movement-row-\(index)", bssid: "DA1020304050", ssid: "Companion",
        timestamp: 1_000_000 + Double(index) * 300_000, latitude: 42 + Double(index) * 0.006,
        longitude: -71, accuracy: 5)
    }
    app.records = rows
    app.afterImport()
    await settle(app)
    let pin = try XCTUnwrap(app.presentation.pins.first)
    app.selectMap(app.presentation.token(for: pin.id))
    XCTAssertEqual(app.selectedMovement?.identity, rows[0].identity)
    XCTAssertEqual(app.selectedMovement?.records.count, 3)
    await app.projectionTask?.value
  }

  func testReanalysisInvalidatesTokensEvenWhenFeaturesAreUnchanged() async throws {
    let app = app()
    await app.start()
    app.records = records()
    app.afterImport()
    await settle(app)
    let old = app.presentation.token(for: "opaque-a")
    app.sensitivity = .high
    app.selectMap(old)
    XCTAssertNil(app.selection)
    await settle(app)
    app.selectMap(old)
    XCTAssertNil(app.selection)
    app.selectMap(app.presentation.token(for: "opaque-a"))
    XCTAssertEqual(app.selectedRecord?.identity, records()[0].identity)
    await app.projectionTask?.value
  }

  func testOutOfOrderAnalysisCannotPublishOrRestoreSelection() async throws {
    let gate = WorkGate<AnalysisInput, AnalysisOutput> { try $0.run() }
    let app = AppCoordinator(
      store: SettingsStore(directory: directory), debounce: .zero,
      analyze: { try await gate.submit($0) })
    await app.start()
    app.records = [records()[0]]
    app.afterImport()
    await gate.waitForArrival(1)
    let old = app.analysisTask
    app.records = [records()[1]]
    app.afterImport()
    await gate.waitForArrival(2)
    let current = app.analysisTask
    await gate.release(2)
    await current?.value
    await app.projectionTask?.value
    let id = app.presentation.id
    await gate.release(1)
    await old?.value
    XCTAssertEqual(app.filtered.map(\.id), ["opaque-b"])
    XCTAssertEqual(app.presentation.id, id)
  }

  func testOutOfOrderProjectionCannotReplaceCurrentMap() async throws {
    let gate = WorkGate<ProjectionInput, MapProjection> { try $0.run() }
    let app = AppCoordinator(
      store: SettingsStore(directory: directory), debounce: .zero,
      project: { try await gate.submit($0) })
    await app.start()
    app.records = records()
    app.afterImport()
    await app.analysisTask?.value
    await gate.waitForArrival(1)
    let old = app.projectionTask
    app.route = true
    await gate.waitForArrival(2)
    let current = app.projectionTask
    await gate.release(2)
    await current?.value
    let id = app.presentation.id
    await gate.release(1)
    await old?.value
    XCTAssertEqual(app.presentation.id, id)
    app.selectMap(app.presentation.token(for: "opaque-a"))
    XCTAssertEqual(app.selectedRecord?.id, "opaque-a")
    await gate.waitForArrival(3)
    await gate.release(3)
    await app.projectionTask?.value
  }

  func testClearRejectsAnAlreadyRunningAnalysis() async throws {
    let gate = WorkGate<AnalysisInput, AnalysisOutput> { try $0.run() }
    let app = AppCoordinator(
      store: SettingsStore(directory: directory), debounce: .zero,
      analyze: { try await gate.submit($0) })
    await app.start()
    app.records = records()
    app.afterImport()
    await gate.waitForArrival(1)
    let old = app.analysisTask
    app.clear()
    await gate.waitForArrival(2)
    await gate.release(2)
    await settle(app)
    await gate.release(1)
    await old?.value
    XCTAssertTrue(app.records.isEmpty)
    XCTAssertTrue(app.filtered.isEmpty)
    XCTAssertTrue(app.presentation.points.isEmpty)
    XCTAssertNil(app.selection)
  }

  func testTrustCachesIncludePendingAdditionsAndRemovals() throws {
    let app = app()
    let rows = SyntheticDrive.records(count: 2_000)
    app.movement = try MovementAnalysis.analyze(rows, catalog: RuleCatalog.load())
    let identities = app.movement.assessments.compactMap(\.identity)
    var settings = SettingsSnapshot()
    settings.savedTrust.devices = Array(identities.prefix(8))
    let absent = TrustedDevice(digest: sha256("absent"), type: .ble)
    settings.savedTrust.devices.append(absent)
    settings.trustOverrides[identities[0]] = false
    settings.trustOverrides[identities[8]] = true
    app.settings = settings
    XCTAssertEqual(app.trustedIdentities, settings.effectiveTrust)
    XCTAssertEqual(app.absentTrusted, [absent])
    XCTAssertEqual(app.trustedRows.map(\.id), app.trustedRows.map(\.id).sorted())
    XCTAssertTrue(
      app.trustedRows.contains(identities[0]),
      "Pending removals must remain available for explicit retry")
    XCTAssertTrue(app.trustedRows.contains(identities[8]))
    for view in MovementView.allCases {
      app.movementView = view
      let expected = app.movement.assessments.filter {
        $0.view(
          trusted: $0.representative.identity.map { settings.effectiveTrust.contains($0) } ?? false)
          == view
      }
      XCTAssertEqual(app.visibleMovement.map(\.id), expected.map(\.id))
    }
    app.settings = .init()
    XCTAssertTrue(app.trustedIdentities.isEmpty)
    XCTAssertTrue(app.trustedRows.isEmpty)
  }

  func testTrustPerformance() throws {
    guard ProcessInfo.processInfo.environment["ATLAS_TRUST_BENCHMARK"] == "1" else {
      throw XCTSkip("Run the release trust benchmark explicitly")
    }
    let app = app()
    let catalog = try RuleCatalog.load()
    for count in [2_000, 10_000, 100_000] {
      app.movement = try MovementAnalysis.analyze(
        SyntheticDrive.records(count: count), catalog: catalog)
      for saved in [0, 1_000, 10_000] {
        var settings = SettingsSnapshot()
        settings.savedTrust.devices = (0..<saved).map {
          .init(digest: sha256("saved-\($0)"), type: .ble)
        }
        app.settings = settings
        let start = ContinuousClock.now
        let visible = app.visibleMovement.count
        let elapsed = start.duration(to: .now)
        print(
          "ATLAS_TRUST_BENCHMARK observations=\(count) assessments=\(app.movement.assessments.count) saved=\(saved) visible=\(visible) elapsed=\(elapsed)"
        )
      }
    }
  }
}
