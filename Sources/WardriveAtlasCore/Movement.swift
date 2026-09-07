import Foundation

public enum Sensitivity: String, CaseIterable, Sendable {
  case high = "High"
  case medium = "Medium"
  case low = "Low"
  public var thresholds: (sightings: Int, locations: Int, minutes: Double, meters: Double) {
    switch self {
    case .high: return (2, 2, 5, 250)
    case .medium: return (3, 2, 10, 500)
    case .low: return (4, 2, 20, 750)
    }
  }
}
public enum MovementView: String, CaseIterable, Sendable {
  case candidates = "Candidates"
  case observed = "Observed"
  case context = "Context"
  case trusted = "Trusted"
}
public struct EvidenceWindow: Codable, Sendable {
  public var first: Double
  public var last: Double
  public var sightingIds: [String]
  public var locations: Int
  public var travelMeters: Double
  public var qualifies: Bool
}
public struct Sighting: Sendable {
  public var record: Observation
  public var location: Int
}
public struct MovementAssessment: Identifiable, Sendable {
  public var id: String
  public let representative: Observation
  public let identity: TrustedDevice?
  public var records: [Observation]
  public var sightings: [Sighting]
  public var locations: Int
  public var sessions: Int
  public var context: String?
  public var contextLabels: [DetectionCategory]
  public var window: EvidenceWindow?
  public func view(trusted: Bool) -> MovementView {
    trusted
      ? .trusted : context != nil ? .context : window?.qualifies == true ? .candidates : .observed
  }
}
public struct Coverage: Equatable, Sendable {
  public var total = 0, eligible = 0, excluded = 0, invalidAddress = 0, invalidTime = 0,
    invalidFix = 0, invalidAccuracy = 0, duplicates = 0, independent = 0, locations = 0
  public init() {}
}
public struct MovementResult: Sendable {
  public var assessments: [MovementAssessment] = []
  public var coverage = Coverage()
  public init() {}
}
public enum Exclusion: String { case invalidAddress, invalidTime, invalidFix, invalidAccuracy }
public enum MovementAnalysis {
  public static let pathGap: Double = 300_000
  public static func distance(_ a: Observation, _ b: Observation) -> Double {
    let latA = a.latitude * .pi / 180
    let latB = b.latitude * .pi / 180
    let h =
      pow(sin((latB - latA) / 2), 2) + cos(latA) * cos(latB)
      * pow(sin((b.longitude - a.longitude) * .pi / 360), 2)
    return 2 * 6_371_000 * asin(sqrt(min(1, max(0, h))))
  }
  public static func usablePosition(_ row: Observation) -> Bool {
    row.latitude.isFinite && row.longitude.isFinite && abs(row.latitude) <= 90
      && abs(row.longitude) <= 180 && (row.latitude != 0 || row.longitude != 0)
  }
  public static func exclusion(_ row: Observation) -> Exclusion? {
    if normalizeAddress(row.bssid) == nil { return .invalidAddress }
    guard let time = row.timestamp, time.isFinite else { return .invalidTime }
    if !usablePosition(row) { return .invalidFix }
    guard let accuracy = row.accuracy, accuracy.isFinite, accuracy > 0, accuracy <= 75 else {
      return .invalidAccuracy
    }
    return nil
  }
  public static func qualifies(
    sightings: Int, locations: Int, elapsed: Double, meters: Double, sensitivity: Sensitivity
  ) -> Bool {
    let t = sensitivity.thresholds
    return sightings >= t.sightings && locations >= t.locations && elapsed >= t.minutes * 60_000
      && meters + 1e-6 >= t.meters
  }
  static func before(_ a: Observation, _ b: Observation) -> Bool {
    if a.timestamp != b.timestamp { return (a.timestamp ?? .infinity) < (b.timestamp ?? .infinity) }
    if a.latitude != b.latitude { return a.latitude < b.latitude }
    if a.longitude != b.longitude { return a.longitude < b.longitude }
    if a.session != b.session { return a.session < b.session }
    return a.id < b.id
  }
  struct Cell: Hashable {
    var x: Int
    var y: Int
    var z: Int
  }
  static func cell(_ row: Observation) -> Cell {
    let lat = row.latitude * .pi / 180
    let lon = row.longitude * .pi / 180
    let scale = 6_371_000.0 / 200
    return Cell(
      x: Int(floor(scale * cos(lat) * cos(lon))), y: Int(floor(scale * cos(lat) * sin(lon))),
      z: Int(floor(scale * sin(lat))))
  }
  public static func independent(_ records: [Observation]) throws -> [Sighting] {
    var minutes: [Double: Observation] = [:]
    for (i, row) in records.enumerated() {
      if i % 256 == 0 { try Task.checkCancellation() }
      guard exclusion(row) == nil else { continue }
      let minute = floor(row.timestamp! / 60_000)
      if let existing = minutes[minute] {
        if row.accuracy! < existing.accuracy!
          || (row.accuracy == existing.accuracy && before(row, existing))
        {
          minutes[minute] = row
        }
      } else {
        minutes[minute] = row
      }
    }
    var anchors: [Observation] = []
    var cells: [Cell: [Int]] = [:]
    var result: [Sighting] = []
    for row in minutes.values.sorted(by: before) {
      try Task.checkCancellation()
      let c = cell(row)
      var location = Int.max
      for dx in -1...1 {
        for dy in -1...1 {
          for dz in -1...1 {
            for index in cells[Cell(x: c.x + dx, y: c.y + dy, z: c.z + dz)] ?? []
            where index < location {
              if distance(anchors[index], row) <= 200 + 1e-6 { location = index }
            }
          }
        }
      }
      if location == Int.max {
        location = anchors.count
        anchors.append(row)
        cells[c, default: []].append(location)
      }
      result.append(Sighting(record: row, location: location))
    }
    return result
  }
  public static func better(_ a: EvidenceWindow?, than b: EvidenceWindow?) -> Bool {
    guard let a else { return false }
    guard let b else { return true }
    return WindowRank(a).isPreferred(to: WindowRank(b))
  }

  /// Shared ranking for a completed window and a window still being scanned.
  private struct WindowRank {
    let window: EvidenceWindow
    let sightingCount: Int
    init(_ window: EvidenceWindow, sightingCount: Int? = nil) {
      self.window = window
      self.sightingCount = sightingCount ?? window.sightingIds.count
    }
    func isPreferred(to other: Self) -> Bool {
      if window.qualifies != other.window.qualifies { return window.qualifies }
      if window.locations != other.window.locations {
        return window.locations > other.window.locations
      }
      if sightingCount != other.sightingCount { return sightingCount > other.sightingCount }
      if window.travelMeters != other.window.travelMeters {
        return window.travelMeters > other.window.travelMeters
      }
      return window.last > other.window.last
    }
  }

  public static func strongestWindow(_ sightings: [Sighting], sensitivity: Sensitivity) throws
    -> EvidenceWindow?
  {
    guard !sightings.isEmpty else { return nil }
    var maxima = Array(repeating: 0.0, count: sightings.count)
    var locations: [Int: Int] = [:]
    var start = 0
    var best: EvidenceWindow?
    var bestRange: Range<Int> = 0..<0
    for end in sightings.indices {
      if end % 64 == 0 { try Task.checkCancellation() }
      let latest = sightings[end].record
      while latest.timestamp! - sightings[start].record.timestamp! > 43_200_000 {
        let location = sightings[start].location
        locations[location, default: 0] -= 1
        if locations[location] == 0 { locations.removeValue(forKey: location) }
        start += 1
      }
      locations[sightings[end].location, default: 0] += 1
      var travel = 0.0
      for index in start..<end {
        let previous = sightings[index].record
        maxima[index] = max(
          maxima[index], distance(previous, latest) - previous.accuracy! - latest.accuracy!)
        travel = max(travel, maxima[index])
      }
      let first = sightings[start].record.timestamp!
      let current = EvidenceWindow(
        first: first, last: latest.timestamp!, sightingIds: [], locations: locations.count,
        travelMeters: travel,
        qualifies: qualifies(
          sightings: end - start + 1, locations: locations.count,
          elapsed: latest.timestamp! - first, meters: travel, sensitivity: sensitivity))
      let count = end - start + 1
      let rank = WindowRank(current, sightingCount: count)
      let replace =
        best.map {
          rank.isPreferred(to: WindowRank($0, sightingCount: bestRange.count))
        } ?? true
      if replace {
        best = current
        bestRange = start..<(end + 1)
      }
    }
    best?.sightingIds = sightings[bestRange].map { $0.record.id }
    return best
  }
  public static func analyze(
    _ records: [Observation], catalog: RuleCatalog, sensitivity: Sensitivity = .medium,
    custom: [CustomPrefix] = []
  ) throws -> MovementResult {
    var result = MovementResult()
    result.coverage.total = records.count
    var settings = RuleSettings()
    settings.custom = custom
    let rules = catalog.compiled(settings).filter { !$0.research && $0.category != .meta }
    var groups: [String: [Observation]] = [:]
    var order: [String] = []
    for (i, row) in records.enumerated() {
      if i % 256 == 0 { try Task.checkCancellation() }
      let key = row.candidateKey
      if groups[key] == nil { order.append(key) }
      groups[key, default: []].append(row)
    }
    for key in order {
      try Task.checkCancellation()
      let rows = groups[key]!
      var eligible: [Observation] = []
      var cameras: Set<DetectionCategory> = []
      for (index, row) in rows.enumerated() {
        if index % 256 == 0 { try Task.checkCancellation() }
        for rule in NotableAnalysis.matches(row, rules: rules, settings: settings) {
          cameras.insert(rule.category)
        }
        if let reason = exclusion(row) {
          result.coverage.excluded += 1
          switch reason {
          case .invalidAddress: result.coverage.invalidAddress += 1
          case .invalidTime: result.coverage.invalidTime += 1
          case .invalidFix: result.coverage.invalidFix += 1
          case .invalidAccuracy: result.coverage.invalidAccuracy += 1
          }
        } else {
          eligible.append(row)
          result.coverage.eligible += 1
        }
      }
      let sightings = try independent(eligible)
      let ordered = rows.sorted(by: before)
      let representative = sightings.last?.record ?? ordered[0]
      let locations = Set(sightings.map(\.location)).count
      let context: String? =
        representative.type == .wifi ? "wifi" : cameras.isEmpty ? nil : "camera"
      var window = try strongestWindow(sightings, sensitivity: sensitivity)
      if context != nil { window?.qualifies = false }
      result.assessments.append(
        MovementAssessment(
          id: "movement-\(result.assessments.count)", representative: representative,
          identity: representative.identity,
          records: ordered, sightings: sightings,
          locations: locations, sessions: Set(rows.map(\.session)).count, context: context,
          contextLabels: cameras.sorted { $0.rawValue < $1.rawValue }, window: window))
      result.coverage.independent += sightings.count
      result.coverage.locations += locations
    }
    result.coverage.duplicates = result.coverage.eligible - result.coverage.independent
    result.assessments.sort {
      better($0.window, than: $1.window) || (!better($1.window, than: $0.window) && $0.id < $1.id)
    }
    return result
  }
  public static func paths(_ records: [Observation], breakGaps: Bool = true) -> [[Observation]] {
    var paths: [[Observation]] = []
    for session in Set(records.map(\.session)).sorted() {
      let rows = records.filter {
        $0.session == session && $0.timestamp != nil && usablePosition($0)
      }.sorted(by: before)
      var segment: [Observation] = []
      for row in rows {
        if breakGaps, let last = segment.last, row.timestamp! - last.timestamp! > pathGap {
          if segment.count > 1 { paths.append(segment) }
          segment = []
        }
        segment.append(row)
      }
      if segment.count > 1 { paths.append(segment) }
    }
    return paths
  }
}
