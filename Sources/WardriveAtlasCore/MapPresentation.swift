import Foundation

public struct MapSelectionToken: Hashable, Sendable {
  public let presentationID: UUID
  public let featureID: String
  public init(presentationID: UUID, featureID: String) {
    self.presentationID = presentationID
    self.featureID = featureID
  }
}

public struct MapPoint: Identifiable, Codable, Sendable {
  public var id: String
  public var latitude: Double
  public var longitude: Double
  public var rssi: Double
  public var radio: Radio
  public var kind: String
  public var weak: Bool
  public var selected: Bool
  public init(
    id: String, latitude: Double, longitude: Double, rssi: Double, radio: Radio,
    kind: String = "observation", weak: Bool = false, selected: Bool = false
  ) {
    self.id = id
    self.latitude = latitude
    self.longitude = longitude
    self.rssi = rssi
    self.radio = radio
    self.kind = kind
    self.weak = weak
    self.selected = selected
  }
}
public struct MapPath: Sendable {
  public var coordinates: [MapPoint]
  public var movement: Bool
}
public struct MapPresentation: Sendable {
  public let id = UUID()
  public var points: [MapPoint] = []
  public var pins: [MapPoint] = []
  public var paths: [MapPath] = []
  public init() {}
  public func token(for featureID: String) -> MapSelectionToken {
    MapSelectionToken(presentationID: id, featureID: featureID)
  }
  public static func pinID(_ resultID: String, index: Int) -> String {
    "\(resultID)/\(index)"
  }
  public static func make(
    records: [Observation], candidates: [Candidate], movement: [MovementAssessment],
    selectedIDs: Set<String>, selectedMovement: MovementAssessment?, route: Bool
  ) throws -> Self {
    var result = Self()
    func point(
      _ row: Observation, id: String? = nil, kind: String = "observation", weak: Bool = false
    ) -> MapPoint {
      MapPoint(
        id: id ?? row.id, latitude: row.latitude, longitude: row.longitude, rssi: row.rssi ?? -100,
        radio: row.type, kind: kind, weak: weak, selected: selectedIDs.contains(row.id))
    }
    for (i, row) in records.enumerated() {
      if i % 512 == 0 { try Task.checkCancellation() }
      result.points.append(point(row))
    }
    for candidate in candidates {
      for (i, row) in candidate.representatives.enumerated() {
        result.pins.append(
          point(
            row, id: pinID(candidate.id, index: i),
            kind: candidate.categories.count > 1 ? "multiple" : candidate.categories[0].rawValue,
            weak: candidate.weak))
      }
    }
    for assessment in movement {
      var last: [String: Observation] = [:]
      for sighting in assessment.sightings { last[sighting.record.session] = sighting.record }
      for (i, session) in last.keys.sorted().enumerated() {
        result.pins.append(
          point(
            last[session]!, id: pinID(assessment.id, index: i), kind: "movement",
            weak: assessment.window?.qualifies != true))
      }
    }
    if route {
      result.paths += MovementAnalysis.paths(records, breakGaps: false).map {
        MapPath(coordinates: $0.map { point($0) }, movement: false)
      }
    }
    if let selectedMovement {
      result.paths += MovementAnalysis.paths(selectedMovement.sightings.map(\.record)).map {
        MapPath(coordinates: $0.map { point($0) }, movement: true)
      }
    }
    return result
  }
}

public enum SyntheticDrive {
  public static func records(count: Int = 240) -> [Observation] {
    (0..<count).map { index in
      let phase = Double(index) / Double(max(1, count - 1))
      let companion = index % 3 == 0
      let radio: Radio = index % 4 == 0 ? .wifi : .ble
      let address =
        companion
        ? "DA:10:20:30:40:50"
        : String(
          format: "DA:00:%02X:%02X:%02X:%02X", (index >> 24) & 255, (index >> 16) & 255,
          (index >> 8) & 255, index & 255)
      let notable = index % 29 == 0
      return Observation(
        id: "sample-\(index)", session: "Synthetic sample drive", bssid: address,
        ssid: notable
          ? "Ray-Ban SAMPLE"
          : companion ? "Sample route companion" : "Sample network \(index % 24)",
        authMode: radio == .wifi ? "WPA2" : "Unknown", security: radio == .wifi ? "WPA2" : "Other",
        timestamp: 1_788_004_800_000 + phase * 3_600_000,
        channel: radio == .wifi ? 6 : 37, band: radio == .wifi ? "2.4 GHz" : "Bluetooth",
        rssi: -80 + 42 * sin(phase * 17) * sin(phase * 17),
        latitude: 42.35 + phase * 0.024, longitude: -71.08 + phase * 0.04 + sin(phase * 12) * 0.003,
        accuracy: 5, manufacturerId: !companion && index % 47 == 0 ? "09C8" : nil,
        type: companion ? .ble : radio)
    }
  }
}
