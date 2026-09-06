import CryptoKit
import Foundation

public enum Radio: String, Codable, CaseIterable, Sendable {
  case wifi = "Wi-Fi"
  case ble = "BLE"
}
public enum PrivacyMode: String, CaseIterable, Codable, Sendable { case show, hash, hide }
public enum MapMode: String, CaseIterable, Sendable {
  case points = "Points"
  case clusters = "Clusters"
  case heatmap = "Heatmap"
}
public enum AtlasError: LocalizedError {
  case invalid(String)
  public var errorDescription: String? {
    if case .invalid(let text) = self { return text }
    return nil
  }
}

public struct Observation: Codable, Identifiable, Hashable, Sendable {
  public var id: String
  public var session: String
  public var bssid: String
  public var ssid: String
  public var authMode: String
  public var security: String
  public var firstSeen: String
  /// Milliseconds since the Unix epoch, matching the capture evidence contract.
  public var timestamp: Double?
  public var channel: Int?
  public var band: String
  public var rssi: Double?
  public var latitude: Double
  public var longitude: Double
  public var altitude: Double?
  public var accuracy: Double?
  public var manufacturerId: String?
  public var type: Radio

  public init(
    id: String = UUID().uuidString, session: String = "Imported session", bssid: String,
    ssid: String,
    authMode: String = "Unknown", security: String = "Other", firstSeen: String = "",
    timestamp: Double? = nil,
    channel: Int? = nil, band: String = "Unknown", rssi: Double? = nil, latitude: Double,
    longitude: Double,
    altitude: Double? = nil, accuracy: Double? = nil, manufacturerId: String? = nil,
    type: Radio = .ble
  ) {
    self.id = id
    self.session = session
    self.bssid = bssid
    self.ssid = ssid
    self.authMode = authMode
    self.security = security
    self.firstSeen = firstSeen
    self.timestamp = timestamp
    self.channel = channel
    self.band = band
    self.rssi = rssi
    self.latitude = latitude
    self.longitude = longitude
    self.altitude = altitude
    self.accuracy = accuracy
    self.manufacturerId = manufacturerId
    self.type = type
  }
  public var candidateKey: String { "\(type.rawValue):\(normalizeAddress(bssid) ?? "row:" + id)" }
  public var identity: TrustedDevice? {
    guard let address = normalizeAddress(bssid) else { return nil }
    return TrustedDevice(
      digest: sha256("wardrive-atlas:co-travel:v1|\(type.rawValue)|\(address)"), type: type)
  }
  public func name(_ mode: PrivacyMode) -> String {
    mode == .hide ? "Private network" : privateLabel(ssid, mode: mode, prefix: "Network")
  }
  public func address(_ mode: PrivacyMode) -> String {
    mode == .show
      ? bssid : privateLabel(normalizeAddress(bssid) ?? bssid, mode: mode, prefix: "Device")
  }
}

public func sha256(_ value: String) -> String {
  SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}
public func privateLabel(_ value: String, mode: PrivacyMode, prefix: String) -> String {
  switch mode {
  case .show: return value
  case .hide: return "Hidden"
  case .hash: return "\(prefix) \(sha256(value.isEmpty ? "unknown" : value).prefix(8))"
  }
}
public func normalizeAddress(_ value: String) -> String? {
  let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard
    text.range(
      of:
        "^(?:[0-9a-f]{12}|(?:[0-9a-f]{2}:){5}[0-9a-f]{2}|(?:[0-9a-f]{2}-){5}[0-9a-f]{2}|(?:[0-9a-f]{4}\\.){2}[0-9a-f]{4})$",
      options: [.regularExpression, .caseInsensitive]) != nil
  else { return nil }
  let result = text.replacingOccurrences(of: "[:.\\-]", with: "", options: .regularExpression)
    .uppercased()
  return ["000000000000", "FFFFFFFFFFFF"].contains(result) ? nil : result
}
public func normalizePrefix(_ value: String) throws -> String {
  let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard
    text.range(
      of: "^(?:[0-9a-f]{6}|(?:[0-9a-f]{2}:){2}[0-9a-f]{2}|(?:[0-9a-f]{2}-){2}[0-9a-f]{2})$",
      options: [.regularExpression, .caseInsensitive]) != nil
  else {
    throw AtlasError.invalid("Enter exactly three hexadecimal bytes, such as B4:1E:52.")
  }
  return text.replacingOccurrences(of: "[:-]", with: "", options: .regularExpression).uppercased()
}

public struct ObservationFilter: Equatable, Sendable {
  public var sessions: Set<String>? = nil
  public var radio: Radio? = nil
  public var band: String? = nil
  public var channel: Int? = nil
  public var security: String? = nil
  public var minimumRSSI: Double = -127
  public var from: Double? = nil
  public var to: Double? = nil
  public init() {}
  public func includes(_ row: Observation) -> Bool {
    if let sessions, !sessions.contains(row.session) { return false }
    if let radio, row.type != radio { return false }
    if let band, row.band != band { return false }
    if let channel, row.channel != channel { return false }
    if let security, row.security != security { return false }
    if (row.rssi ?? -127) < minimumRSSI { return false }
    if let from, (row.timestamp ?? -.infinity) < from { return false }
    if let to, (row.timestamp ?? .infinity) > to { return false }
    return true
  }
  public func apply(_ rows: [Observation]) throws -> [Observation] {
    var output: [Observation] = []
    output.reserveCapacity(rows.count)
    for (i, row) in rows.enumerated() {
      if i % 512 == 0 { try Task.checkCancellation() }
      if includes(row) { output.append(row) }
    }
    return output
  }
}
