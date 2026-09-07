import Foundation
import Testing

@testable import WardriveAtlasCore

private final class FixtureLocator {}
private var fixtures: Bundle {
  #if SWIFT_PACKAGE
    return .module
  #else
    return Bundle(for: FixtureLocator.self)
  #endif
}
func row(_ minute: Double = 0, _ meters: Double = 0, id: String? = nil) -> Observation {
  Observation(
    id: id ?? "row-\(minute)-\(meters)", session: "synthetic-drive.csv", bssid: "DA:10:20:30:40:50",
    ssid: "Synthetic companion",
    timestamp: 1_788_091_200_000 + minute * 60_000, rssi: -60,
    latitude: 42 + meters / 6_371_000 * 180 / .pi, longitude: -71, accuracy: 5)
}
func drive() -> [Observation] { [row(), row(5, 350), row(10, 700)] }
func fixture(_ name: String, extension ext: String = "csv") throws -> Data {
  try Data(contentsOf: #require(fixtures.url(forResource: name, withExtension: ext)))
}

struct ImportTests {
  @Test func quotedFieldsAndMetadata() throws {
    #expect(
      try CSVImporter.rows("\u{FEFF}SSID,Note\r\n\"Cafe, North\",\"Say \"\"hello\"\"\nagain\"\r\n")
        == [["SSID", "Note"], ["Cafe, North", "Say \"hello\"\nagain"]])
    let data = try fixture("notable-morning")
    let records = try CSVImporter.parse(String(decoding: data, as: UTF8.self), session: "morning")
    #expect(records.count == 7)
    #expect(records[0].manufacturerId == "09C8")
    #expect(records[0].ssid.contains(", morning"))
  }
  @Test(arguments: ["09C8", "0x09c8", "9c8"])
  func manufacturerNormalization(_ value: String) {
    #expect(CSVImporter.manufacturer(value) == "09C8")
  }
  @Test(arguments: ["", "nope", "12345", "09:C8"])
  func invalidManufacturer(_ value: String) { #expect(CSVImporter.manufacturer(value) == nil) }
  @Test func invalidRowsAndFallbacks() throws {
    let csv =
      "MAC,SSID,CurrentLatitude,CurrentLongitude,MfgrId,AccuracyMeters\naa,,42,-71,nope,\nbb,a,95,-71,,\ncc,b,42,-71,,-1\ndd,c,42,-71,,0"
    let records = try CSVImporter.parse(csv, session: "capture")
    #expect(records.count == 2)
    #expect(records[0].ssid == "Hidden network")
    #expect(records[0].manufacturerId == nil)
    #expect(records[0].timestamp == nil)
    #expect(records[1].accuracy == 0)
    #expect(throws: (any Error).self) {
      try CSVImporter.parse("name,value\nfoo,bar", session: "bad")
    }
    #expect(throws: (any Error).self) {
      try CSVImporter.parse("MAC,SSID,CurrentLatitude,CurrentLongitude\na,b,95,200", session: "bad")
    }
  }
  @Test func timezoneAndMissingTime() throws {
    let csv =
      "MAC,SSID,CurrentLatitude,CurrentLongitude,FirstSeen\na,b,42,-71,2026-08-29 10:30:00\na,b,42,-71,2026-08-29T10:30:00-04:00\na,b,42,-71,2026-08-29T14:30:00Z\na,b,42,-71,invalid"
    let records = try CSVImporter.parse(
      csv, session: "times", timeZone: #require(TimeZone(identifier: "America/New_York")))
    #expect(records[0].timestamp == records[1].timestamp)
    #expect(records[1].timestamp == records[2].timestamp)
    #expect(records[3].timestamp == nil)
  }
  @Test func channelsSecurityAndSessionNames() {
    #expect(CSVImporter.band(channel: 6, radio: .wifi) == "2.4 GHz")
    #expect(CSVImporter.band(channel: 149, radio: .wifi) == "5 GHz")
    #expect(CSVImporter.band(channel: 213, radio: .wifi) == "6 GHz")
    #expect(CSVImporter.band(channel: nil, radio: .ble) == "Bluetooth")
    #expect(CSVImporter.security("[WPA3-SAE]") == "WPA3")
    #expect(CSVImporter.security("[ESS]") == "Other")
    #expect(CSVImporter.security("OPEN") == "Open")
    #expect(
      CSVImporter.uniqueSession("drive.csv", existing: ["drive.csv", "drive.csv (2)"])
        == "drive.csv (3)")
  }
  @Test func filters() throws {
    let records = drive()
    var filter = ObservationFilter()
    #expect(try filter.apply(records).count == 3)
    filter.from = records[1].timestamp
    #expect(try filter.apply(records).count == 2)
    filter.to = records[1].timestamp
    #expect(try filter.apply(records).count == 1)
    filter.minimumRSSI = -50
    #expect(try filter.apply(records).isEmpty)
    filter = .init()
    filter.radio = .wifi
    #expect(try filter.apply(records).isEmpty)
    filter = .init()
    filter.sessions = []
    #expect(try filter.apply(records).isEmpty)
    filter = .init()
    filter.band = "5 GHz"
    #expect(try filter.apply(records).isEmpty)
    filter = .init()
    filter.channel = 6
    #expect(try filter.apply(records).isEmpty)
    filter = .init()
    filter.security = "WPA2"
    #expect(try filter.apply(records).isEmpty)
  }
}

struct NotableTests {
  @Test(arguments: ["b4:1e:52:00:00:01", "B4-1E-52-00-00-01", "B41E.5200.0001", "B41E52000001"])
  func validAddress(_ value: String) { #expect(normalizeAddress(value) == "B41E52000001") }
  @Test(arguments: ["", "unknown", "B4:1E:52", "B4:1E-52:00:00:01", "000000000000", "FFFFFFFFFFFF"])
  func invalidAddress(_ value: String) { #expect(normalizeAddress(value) == nil) }
  @Test func referenceParity() throws {
    let data = try fixture("legacy-reference", extension: "json")
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let records = try JSONDecoder().decode(
      [Observation].self, from: JSONSerialization.data(withJSONObject: object["records"]!))
    let catalog = try RuleCatalog.load()
    #expect(catalog.version == "2026-08-30.1")
    #expect(catalog.rules.allSatisfy { $0.source?.hasPrefix("https://") == true })
    let candidates = try NotableAnalysis.analyze(records, catalog: catalog, research: true)
    let expected = try #require(object["candidates"] as? [[String: Any]])
    #expect(candidates.count == expected.count)
    for (candidate, entry) in zip(candidates, expected) {
      #expect(candidate.key == entry["key"] as? String)
      #expect(candidate.records.map(\.id) == entry["recordIds"] as? [String])
      #expect(candidate.representatives.map(\.id) == entry["representativeIds"] as? [String])
      #expect(candidate.evidence.map(\.id) == entry["evidence"] as? [String])
      #expect(candidate.categories.map(\.rawValue) == entry["categories"] as? [String])
    }
    #expect(try NotableAnalysis.analyze(records, catalog: catalog).count == 3)
    let result = try MovementAnalysis.analyze(records, catalog: catalog)
    let legacy = try #require(object["movement"] as? [String: Any])
    let coverage = try #require(legacy["coverage"] as? [String: Int])
    #expect(result.coverage.total == coverage["total"])
    #expect(result.coverage.invalidAccuracy == coverage["invalidAccuracy"])
    #expect(result.assessments.count == (legacy["assessments"] as? [Any])?.count)
  }
  @Test(arguments: [
    "Penguin-123", "flock-SAMPLE", "pigvision", "FS Ext Battery", "Ray-Ban SAMPLE", "My wayfarer",
    "Oakley Meta",
  ])
  func namesOnlyBluetooth(_ name: String) throws {
    let catalog = try RuleCatalog.load()
    var record = row()
    record.ssid = name
    #expect(!NotableAnalysis.matches(record, rules: catalog.rules, settings: .init()).isEmpty)
    record.type = .wifi
    #expect(NotableAnalysis.matches(record, rules: catalog.rules, settings: .init()).isEmpty)
  }
  @Test func optionalEvidenceAndFalsePositives() throws {
    let rules = try RuleCatalog.load().rules
    var record = row()
    for name in ["My flock of birds", "Penguin-", "01234567890"] {
      record.ssid = name
      #expect(NotableAnalysis.matches(record, rules: rules, settings: .init()).isEmpty)
    }
    record.ssid = "ordinary"
    record.manufacturerId = "0D53"
    #expect(NotableAnalysis.matches(record, rules: rules, settings: .init()).isEmpty)
    record.manufacturerId = "09C8"
    #expect(
      NotableAnalysis.matches(record, rules: rules, settings: .init()).map(\.id) == [
        "flock-company"
      ])
    record.type = .wifi
    #expect(NotableAnalysis.matches(record, rules: rules, settings: .init()).isEmpty)
  }
  @Test(arguments: ["F8A2D6", "CCCCCC", "000CE7", "942A6F", "F4E2C6", "6CCDD6"])
  func withdrawnPrefixes(_ prefix: String) throws {
    var record = row()
    record.type = .wifi
    record.bssid = prefix + "000001"
    #expect(
      NotableAnalysis.matches(
        record, rules: try RuleCatalog.load().rules, settings: .init(), research: true
      ).isEmpty)
  }
  @Test func researchCustomIgnoredAndDismissed() throws {
    let catalog = try RuleCatalog.load()
    var record = row()
    record.bssid = "82:6B:F2:00:00:01"
    record.type = .wifi
    #expect(try NotableAnalysis.analyze([record], catalog: catalog).isEmpty)
    #expect(
      try NotableAnalysis.analyze([record], catalog: catalog, research: true).first?.weak == true)
    var settings = RuleSettings()
    settings.custom = [.init(prefix: "826BF2", category: .axon, protocol: .both)]
    #expect(
      try NotableAnalysis.analyze([record], catalog: catalog, settings: settings).first?.categories
        == [.axon])
    settings.ignored = [.init(prefix: "826BF2", protocol: .wifi)]
    #expect(
      try NotableAnalysis.analyze([record], catalog: catalog, settings: settings, research: true)
        .isEmpty)
    #expect(
      try NotableAnalysis.analyze(
        [record], catalog: catalog, research: true, dismissed: [record.candidateKey]
      ).isEmpty)
    record.bssid = "83:6B:F2:00:00:01"
    settings.custom[0].prefix = "836BF2"
    #expect(try NotableAnalysis.analyze([record], catalog: catalog, settings: settings).isEmpty)
  }
  @Test func groupingAndRepresentative() throws {
    let catalog = try RuleCatalog.load()
    var a = row()
    var b = row(1)
    var c = row(2)
    a.bssid = "unknown"
    b.bssid = "unknown"
    a.ssid = "Ray-Ban"
    b.ssid = "Ray-Ban"
    #expect(try NotableAnalysis.analyze([a, b], catalog: catalog).count == 2)
    a.bssid = "DA1020304050"
    b.bssid = a.bssid
    c.bssid = a.bssid
    c.ssid = "ordinary"
    a.rssi = nil
    b.rssi = nil
    c.rssi = nil
    a.timestamp = nil
    let candidate = try #require(NotableAnalysis.analyze([a, b, c], catalog: catalog).first)
    #expect(candidate.records.count == 3)
    #expect(candidate.representatives.first?.id == b.id)
  }
  @Test func ruleValidation() throws {
    let valid = Data(
      #"{"version":1,"custom":[{"prefix":"b4:1e:52","category":"flock","protocol":"BLE"}],"ignored":[]}"#
        .utf8)
    let settings = try RuleSettings.parse(valid)
    #expect(settings.custom[0].prefix == "B41E52")
    #expect(try settings.merging(settings).custom.count == 1)
    for invalid in [
      #"{"version":2,"custom":[],"ignored":[]}"#,
      #"{"version":1,"custom":[],"ignored":[],"extra":1}"#,
      #"{"version":1,"custom":[{"prefix":"nope","category":"flock","protocol":"BLE"}],"ignored":[]}"#,
    ] {
      #expect(throws: (any Error).self) { try RuleSettings.parse(Data(invalid.utf8)) }
    }
    #expect(throws: (any Error).self) {
      try RuleSettings.parse(Data(repeating: 32, count: 128_001))
    }
    var oversized = RuleSettings()
    oversized.custom = Array(repeating: settings.custom[0], count: 501)
    #expect(throws: (any Error).self) { try RuleSettings.parse(JSONEncoder().encode(oversized)) }
  }
}

struct MovementTests {
  @Test(arguments: Sensitivity.allCases)
  func thresholds(_ sensitivity: Sensitivity) throws {
    let t = sensitivity.thresholds
    #expect(
      MovementAnalysis.qualifies(
        sightings: t.sightings, locations: t.locations, elapsed: t.minutes * 60_000,
        meters: t.meters, sensitivity: sensitivity))
    #expect(
      !MovementAnalysis.qualifies(
        sightings: t.sightings - 1, locations: t.locations, elapsed: t.minutes * 60_000,
        meters: t.meters, sensitivity: sensitivity))
    #expect(
      !MovementAnalysis.qualifies(
        sightings: t.sightings, locations: t.locations - 1, elapsed: t.minutes * 60_000,
        meters: t.meters, sensitivity: sensitivity))
    #expect(
      !MovementAnalysis.qualifies(
        sightings: t.sightings, locations: t.locations, elapsed: t.minutes * 60_000 - 1,
        meters: t.meters, sensitivity: sensitivity))
    #expect(
      !MovementAnalysis.qualifies(
        sightings: t.sightings, locations: t.locations, elapsed: t.minutes * 60_000,
        meters: t.meters - 0.01, sensitivity: sensitivity))
  }
  @Test func geometryAndStationary() throws {
    let catalog = try RuleCatalog.load()
    let result = try #require(MovementAnalysis.analyze(drive(), catalog: catalog).assessments.first)
    #expect(result.window?.qualifies == true)
    #expect(abs((result.window?.travelMeters ?? 0) - 690) < 0.001)
    #expect(result.view(trusted: false) == .candidates)
    #expect(result.view(trusted: true) == .trusted)
    for rows in [
      [row(), row(5, 50), row(10, -50), row(20)], [row(), row(5, 300), row(10), row(20, 300)],
    ] {
      #expect(
        try MovementAnalysis.analyze(rows, catalog: catalog).assessments[0].window?.qualifies
          == false)
    }
    var poor = drive()
    for i in poor.indices {
      poor[i].accuracy = 75
      poor[i].rssi = -20
    }
    #expect(
      abs(
        (try MovementAnalysis.analyze(poor, catalog: catalog).assessments[0].window?.travelMeters
          ?? 0) - 550) < 0.001)
  }
  @Test func fixedAnchorsAndMinuteDedup() throws {
    #expect(
      try MovementAnalysis.independent([row(), row(1, 150), row(2, 300), row(3, 450), row(4, 600)])
        .map(\.location) == [0, 0, 1, 1, 2])
    #expect(
      try MovementAnalysis.independent([row(), row(1, 200), row(2, 200.01)]).map(\.location) == [
        0, 0, 1,
      ])
    var a = row(0.1)
    var b = row(0.9, 400)
    a.accuracy = 50
    b.accuracy = 5
    #expect(try MovementAnalysis.independent([a, b]).first?.record.id == b.id)
    b.session = "overlap.csv"
    var c = b
    c.id = "duplicate"
    c.session = "another.csv"
    #expect(try MovementAnalysis.independent([b, c]).count == 1)
    #expect(try MovementAnalysis.independent([b, c]).first?.record.id == "duplicate")
  }
  @Test func coverageAndContext() throws {
    let catalog = try RuleCatalog.load()
    var invalid = drive()
    invalid[0].bssid = "invalid"
    invalid[0].timestamp = nil
    invalid[1].timestamp = nil
    invalid[2].accuracy = 0
    let result = try MovementAnalysis.analyze(invalid, catalog: catalog)
    #expect(result.coverage.invalidAddress == 1)
    #expect(result.coverage.invalidTime == 1)
    #expect(result.coverage.invalidAccuracy == 1)
    #expect(result.assessments.reduce(0) { $0 + $1.records.count } == 3)
    var zero = row()
    zero.latitude = 0
    zero.longitude = 0
    #expect(MovementAnalysis.exclusion(zero) == .invalidFix)
    for manufacturer in ["09C8", "034D"] {
      let rows = drive().map { row -> Observation in
        var r = row
        r.manufacturerId = manufacturer
        return r
      }
      let assessment = try MovementAnalysis.analyze(rows, catalog: catalog).assessments[0]
      #expect(assessment.view(trusted: false) == .context)
      #expect(assessment.window?.qualifies == false)
    }
    let meta = drive().map { row -> Observation in
      var r = row
      r.ssid = "Ray-Ban SAMPLE"
      return r
    }
    #expect(
      try MovementAnalysis.analyze(meta, catalog: catalog).assessments[0].window?.qualifies == true)
  }
  @Test func rotatingAddressesAndRadios() throws {
    let catalog = try RuleCatalog.load()
    let rotating = drive().enumerated().map { i, r -> Observation in
      var row = r
      row.bssid = "DA102030405\(i)"
      return row
    }
    #expect(try MovementAnalysis.analyze(rotating, catalog: catalog).assessments.count == 3)
    let wifi = drive().map { r -> Observation in
      var row = r
      row.type = .wifi
      row.id += "-wifi"
      return row
    }
    #expect(try MovementAnalysis.analyze(drive() + wifi, catalog: catalog).assessments.count == 2)
  }
  @Test func windowsExpireAndOrdering() throws {
    let catalog = try RuleCatalog.load()
    let rows = [row(), row(5, 350), row(721, 700)]
    #expect(
      try MovementAnalysis.analyze(rows, catalog: catalog).assessments[0].window?.qualifies == false
    )
    let a = try MovementAnalysis.analyze(drive(), catalog: catalog).assessments[0]
    let b = try MovementAnalysis.analyze(drive().reversed(), catalog: catalog).assessments[0]
    #expect(a.window?.sightingIds == b.window?.sightingIds)
    #expect(a.window?.travelMeters == b.window?.travelMeters)
  }
  @Test func rollingWindowOracle() throws {
    let rows = (0..<180).map { row(Double($0 * 7), Double(($0 * 173) % 2700)) }
    let sightings = try MovementAnalysis.independent(rows)
    let actual = try MovementAnalysis.strongestWindow(sightings, sensitivity: .medium)
    var expected: EvidenceWindow?
    for end in sightings.indices {
      let eligible = sightings[...end].filter {
        sightings[end].record.timestamp! - $0.record.timestamp! <= 43_200_000
      }
      var span = 0.0
      for a in eligible.indices {
        for b in eligible.indices where b > a {
          span = max(
            span,
            MovementAnalysis.distance(eligible[a].record, eligible[b].record) - eligible[a].record
              .accuracy! - eligible[b].record.accuracy!)
        }
      }
      let first = eligible[0].record.timestamp!
      let last = eligible.last!.record.timestamp!
      let locations = Set(eligible.map(\.location)).count
      let window = EvidenceWindow(
        first: first, last: last, sightingIds: eligible.map { $0.record.id }, locations: locations,
        travelMeters: span,
        qualifies: MovementAnalysis.qualifies(
          sightings: eligible.count, locations: locations, elapsed: last - first, meters: span,
          sensitivity: .medium))
      if MovementAnalysis.better(window, than: expected) { expected = window }
    }
    #expect(actual?.sightingIds == expected?.sightingIds)
    #expect(actual?.travelMeters == expected?.travelMeters)
  }
  @Test func mapPrivacyAndPaths() throws {
    let records = drive()
    let catalog = try RuleCatalog.load()
    let result = try MovementAnalysis.analyze(records, catalog: catalog)
    let map = try MapPresentation.make(
      records: records, candidates: [], movement: result.assessments, selectedIDs: [],
      selectedMovement: result.assessments[0], route: false)
    #expect(map.pins.count == 1)
    #expect(map.paths.count == 1)
    let text = String(decoding: try JSONEncoder().encode(map.points + map.pins), as: UTF8.self)
    #expect(!text.contains(records[0].ssid))
    #expect(!text.contains(records[0].bssid))
    #expect(!text.contains(records[0].session))
    #expect(MovementAnalysis.paths([row(), row(5, 350), row(10.001, 700)]).count == 1)
    var separate = row(5, 350)
    separate.session = "other"
    #expect(MovementAnalysis.paths([row(), separate]).isEmpty)
  }
  @Test func cancellation() async throws {
    let task = Task.detached { () throws -> [Sighting] in
      while !Task.isCancelled { await Task.yield() }
      return try MovementAnalysis.independent(drive())
    }
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Cancelled analysis returned results")
    } catch { #expect(error is CancellationError) }
    let parser = Task.detached { () throws -> [[String]] in
      while !Task.isCancelled { await Task.yield() }
      return try CSVImporter.rows(String(repeating: "a,b,c\n", count: 100_000))
    }
    parser.cancel()
    do {
      _ = try await parser.value
      Issue.record("Cancelled import returned results")
    } catch { #expect(error is CancellationError) }
  }
}

struct SampleTests {
  @Test func sharedRouteSampleQualifies() throws {
    let result = try MovementAnalysis.analyze(SyntheticDrive.records(), catalog: RuleCatalog.load())
    #expect(
      result.assessments.contains {
        $0.representative.ssid == "Sample route companion" && $0.window?.qualifies == true
      })
  }
}

struct ReviewRegressionTests {
  @Test(arguments: ["America/New_York", "Asia/Tokyo"])
  func explicitOffsetsUseTheirOwnTimezone(_ zone: String) throws {
    for fraction in ["", ".125"] {
      let equivalent = [
        "2026-08-29T14:30:00\(fraction)Z", "2026-08-29 14:30:00\(fraction)Z",
        "2026-08-29T10:30:00\(fraction)-04:00", "2026-08-29 10:30:00\(fraction)-04:00",
        "2026-08-29T16:30:00\(fraction)+02:00", "2026-08-29 16:30:00\(fraction)+02:00",
        "2026-08-29 10:30:00\(fraction)-0400", "2026-08-29 16:30:00\(fraction)+0200",
      ]
      let csv =
        "MAC,SSID,CurrentLatitude,CurrentLongitude,FirstSeen\n"
        + equivalent.map { "DA1020304050,Example,42,-71,\($0)" }.joined(separator: "\n")
      let rows = try CSVImporter.parse(
        csv, session: "offsets", timeZone: #require(TimeZone(identifier: zone)))
      let expected = try #require(rows[0].timestamp)
      #expect(rows.allSatisfy { $0.timestamp == expected })
    }
    let csv =
      "MAC,SSID,CurrentLatitude,CurrentLongitude,FirstSeen\nDA1020304050,Example,42,-71,not 2026-08-29 14:30:00Z"
    #expect(try CSVImporter.parse(csv, session: "invalid")[0].timestamp == nil)
  }

  @Test func rankingUsesEveryTieBreakerInOrder() {
    func window(
      _ qualified: Bool, _ locations: Int, _ sightings: Int, _ span: Double, _ last: Double
    ) -> EvidenceWindow {
      EvidenceWindow(
        first: 0, last: last, sightingIds: (0..<sightings).map(String.init),
        locations: locations, travelMeters: span, qualifies: qualified)
    }
    let ordered = [
      window(true, 2, 3, 500, 10), window(false, 4, 6, 900, 20),
      window(false, 3, 8, 1_000, 30), window(false, 3, 7, 1_100, 40),
      window(false, 3, 7, 1_000, 50), window(false, 3, 7, 1_000, 40),
    ]
    for a in ordered.indices {
      #expect(!MovementAnalysis.better(ordered[a], than: ordered[a]))
      for b in ordered.indices where b > a {
        #expect(MovementAnalysis.better(ordered[a], than: ordered[b]))
        #expect(!MovementAnalysis.better(ordered[b], than: ordered[a]))
      }
    }
    #expect(!MovementAnalysis.better(nil, than: ordered[0]))
    #expect(MovementAnalysis.better(ordered[0], than: nil))
  }
}
