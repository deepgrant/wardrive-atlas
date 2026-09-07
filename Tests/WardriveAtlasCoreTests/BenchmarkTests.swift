import Darwin
import Foundation
import Testing

@testable import WardriveAtlasCore

@Suite(.serialized)
struct BenchmarkTests {
  @Test(arguments: [10_000, 100_000])
  func captureWorkload(_ count: Int) throws {
    guard ProcessInfo.processInfo.environment["ATLAS_BENCHMARK"] == "1" else { return }
    let catalog = try RuleCatalog.load()
    let generated = SyntheticDrive.records(count: count)
    let header = "MAC,SSID,CurrentLatitude,CurrentLongitude,FirstSeen,RSSI,AccuracyMeters,Type"
    let csv =
      header + "\n"
      + generated.map {
        "\($0.bssid),\($0.ssid),\($0.latitude),\($0.longitude),2026-08-29T10:\(String(format: "%02d", Int(($0.timestamp ?? 0) / 60_000) % 60)):00Z,\($0.rssi ?? -100),5,\($0.type.rawValue)"
      }.joined(separator: "\n")
    let clock = ContinuousClock()
    let start = clock.now
    let records = try CSVImporter.parse(csv, session: "Benchmark")
    let imported = clock.now
    var filter = ObservationFilter()
    filter.minimumRSSI = -60
    let filtered = try filter.apply(records)
    let filteredAt = clock.now
    let candidates = try NotableAnalysis.analyze(filtered, catalog: catalog)
    let movement = try MovementAnalysis.analyze(filtered, catalog: catalog)
    let analyzedAt = clock.now
    let map = try MapPresentation.make(
      records: filtered, candidates: candidates, movement: movement.assessments, selectedIDs: [],
      selectedMovement: nil, route: false)
    let finished = clock.now
    #expect(records.count == count)
    #expect(map.points.count == filtered.count)
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    print("ATLAS_MEMORY peakResidentMiB=\(Double(usage.ru_maxrss) / 1_048_576)")
    print(
      "ATLAS_BENCHMARK rows=\(count) import=\(start.duration(to: imported)) filter=\(imported.duration(to: filteredAt)) analysis=\(filteredAt.duration(to: analyzedAt)) projection=\(analyzedAt.duration(to: finished)) total=\(start.duration(to: finished))"
    )
  }
}
