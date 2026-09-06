import Foundation

public enum DetectionCategory: String, Codable, CaseIterable, Sendable {
  case flock, axon, meta
  public var title: String {
    switch self {
    case .flock: return "Flock"
    case .axon: return "Axon"
    case .meta: return "Meta glasses"
    }
  }
  public var symbol: String {
    switch self {
    case .flock: return "video.fill"
    case .axon: return "camera.fill"
    case .meta: return "eyeglasses"
    }
  }
}
public enum RuleProtocol: String, Codable, CaseIterable, Sendable {
  case both = "Both"
  case wifi = "Wi-Fi"
  case ble = "BLE"
  public func includes(_ radio: Radio) -> Bool { self == .both || rawValue == radio.rawValue }
}
public struct CustomPrefix: Codable, Hashable, Sendable {
  public var prefix: String
  public var category: DetectionCategory
  public var `protocol`: RuleProtocol
  public init(prefix: String, category: DetectionCategory, protocol radio: RuleProtocol) {
    self.prefix = prefix
    self.category = category
    self.protocol = radio
  }
}
public struct IgnoredPrefix: Codable, Hashable, Sendable {
  public var prefix: String
  public var `protocol`: RuleProtocol
  public init(prefix: String, protocol radio: RuleProtocol) {
    self.prefix = prefix
    self.protocol = radio
  }
}
public struct RuleSettings: Codable, Equatable, Sendable {
  public var version = 1
  public var custom: [CustomPrefix] = []
  public var ignored: [IgnoredPrefix] = []
  public init() {}
  public static func parse(_ data: Data) throws -> RuleSettings {
    guard data.count <= 128_000 else {
      throw AtlasError.invalid("Rule files must be smaller than 128 KB.")
    }
    let object = try JSONSerialization.jsonObject(with: data)
    try validateKeys(object, keys: ["version", "custom", "ignored"])
    if let object = object as? [String: Any] {
      for item in object["custom"] as? [Any] ?? [] {
        try validateKeys(item, keys: ["prefix", "category", "protocol"])
      }
      for item in object["ignored"] as? [Any] ?? [] {
        try validateKeys(item, keys: ["prefix", "protocol"])
      }
    }
    var settings = try JSONDecoder().decode(Self.self, from: data)
    guard settings.version == 1, settings.custom.count <= 500, settings.ignored.count <= 500 else {
      throw AtlasError.invalid("Unsupported rules version or more than 500 entries per rule type.")
    }
    for index in settings.custom.indices {
      settings.custom[index].prefix = try normalizePrefix(settings.custom[index].prefix)
    }
    for index in settings.ignored.indices {
      settings.ignored[index].prefix = try normalizePrefix(settings.ignored[index].prefix)
    }
    return settings
  }
  public func merging(_ other: Self) throws -> Self {
    var value = self
    for item in other.custom where !value.custom.contains(item) { value.custom.append(item) }
    for item in other.ignored where !value.ignored.contains(item) { value.ignored.append(item) }
    return try Self.parse(JSONEncoder().encode(value))
  }
}
func validateKeys(_ object: Any, keys: Set<String>) throws {
  guard let dictionary = object as? [String: Any], Set(dictionary.keys) == keys else {
    throw AtlasError.invalid("The settings file contains missing or unsupported fields.")
  }
}
public struct DetectionRule: Codable, Identifiable, Sendable {
  public struct Match: Codable, Sendable {
    public var kind: String
    public var value: String?
    public var allowLocal: Bool?
    public var mode: String?
  }
  public var id: String
  public var category: DetectionCategory
  public var protocols: [Radio]
  public var match: Match
  public var research: Bool
  public var custom: Bool
  public var explanation: String
  public var source: String?
  public var sourceLabel: String
  public var rank: Int { research ? 2 : match.kind == "prefix" ? 1 : 0 }
  public var label: String {
    research
      ? "Research lead"
      : custom
        ? "User-defined prefix"
        : match.kind == "prefix"
          ? "Vendor prefix" : match.kind == "manufacturer" ? "Manufacturer ID" : "Device name"
  }
}
public struct RuleCatalog: Codable, Sendable {
  public var version: String
  public var reviewed: String
  public var rules: [DetectionRule]
  public static func load() throws -> Self {
    guard let url = AtlasResources.bundle.url(forResource: "catalog", withExtension: "json") else {
      throw AtlasError.invalid("The bundled rule catalog is missing.")
    }
    let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    guard Set(catalog.rules.map(\.id)).count == catalog.rules.count else {
      throw AtlasError.invalid("Duplicate catalog rule identifiers.")
    }
    return catalog
  }
  public func compiled(_ settings: RuleSettings) -> [DetectionRule] {
    rules
      + settings.custom.enumerated().map { index, rule in
        DetectionRule(
          id: "custom-\(index)", category: rule.category,
          protocols: Radio.allCases.filter(rule.protocol.includes),
          match: .init(kind: "prefix", value: rule.prefix, allowLocal: true, mode: nil),
          research: false, custom: true,
          explanation:
            "Matched a prefix you added. This is user-defined evidence, not an independently verified hardware classification.",
          source: nil, sourceLabel: "Your custom rule")
      }
  }
}
public struct Candidate: Identifiable, Sendable {
  public var id: String
  public var key: String
  public var records: [Observation]
  public var representatives: [Observation]
  public var evidence: [DetectionRule]
  public var categories: [DetectionCategory]
  public var strongest: Double?
  public var firstSeen: Double?
  public var lastSeen: Double?
  public var weak: Bool { evidence.allSatisfy(\.research) }
}
public enum CandidateSort: String, CaseIterable, Sendable {
  case evidence = "Evidence"
  case signal = "Signal"
  case recent = "Recent"
}
public enum NotableAnalysis {
  public static func matches(
    _ record: Observation, rules: [DetectionRule], settings: RuleSettings, research: Bool = false
  ) -> [DetectionRule] {
    let address = normalizeAddress(record.bssid)
    if let address,
      settings.ignored.contains(where: {
        $0.protocol.includes(record.type) && address.hasPrefix($0.prefix)
      })
    {
      return []
    }
    return rules.filter { rule in
      guard research || !rule.research, rule.protocols.contains(record.type) else { return false }
      let match = rule.match
      let value = rule.match.value ?? ""
      switch match.kind {
      case "prefix":
        guard let address, address.hasPrefix(value) else { return false }
        if record.type == .wifi, let byte = Int(address.prefix(2), radix: 16) {
          if byte & 1 != 0 || (byte & 2 != 0 && match.allowLocal != true) { return false }
        }
        return true
      case "manufacturer": return record.manufacturerId == value
      case "serial":
        return record.ssid.trimmingCharacters(in: .whitespacesAndNewlines).range(
          of: "^[0-9]{10}$", options: .regularExpression) != nil
      case "name":
        let name = record.ssid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let target = value.lowercased()
        switch match.mode {
        case "starts": return name.hasPrefix(target) && name.count > target.count
        case "exact": return name == target
        default: return name.contains(target)
        }
      default: return false
      }
    }
  }
  public static func analyze(
    _ records: [Observation], catalog: RuleCatalog, settings: RuleSettings = .init(),
    research: Bool = false, dismissed: Set<String> = []
  ) throws -> [Candidate] {
    let rules = catalog.compiled(settings)
    var groups: [String: [Observation]] = [:]
    var order: [String] = []
    for (i, row) in records.enumerated() {
      if i % 256 == 0 { try Task.checkCancellation() }
      let key = row.candidateKey
      if dismissed.contains(key) { continue }
      if groups[key] == nil { order.append(key) }
      groups[key, default: []].append(row)
    }
    var candidates: [Candidate] = []
    for key in order {
      try Task.checkCancellation()
      let rows = groups[key]!
      var evidence: [String: DetectionRule] = [:]
      var reps: [String: Observation] = [:]
      var sessionOrder: [String] = []
      for (index, row) in rows.enumerated() {
        if index % 256 == 0 { try Task.checkCancellation() }
        for match in matches(row, rules: rules, settings: settings, research: research) {
          evidence[match.id] = match
        }
        if reps[row.session] == nil { sessionOrder.append(row.session) }
        if let existing = reps[row.session] {
          if (row.rssi ?? -.infinity) > (existing.rssi ?? -.infinity)
            || (row.rssi == existing.rssi
              && (row.timestamp ?? .infinity) < (existing.timestamp ?? .infinity))
          {
            reps[row.session] = row
          }
        } else {
          reps[row.session] = row
        }
      }
      guard !evidence.isEmpty else { continue }
      let sorted = evidence.values.sorted { $0.rank == $1.rank ? $0.id < $1.id : $0.rank < $1.rank }
      candidates.append(
        Candidate(
          id: "candidate-\(candidates.count)", key: key, records: rows,
          representatives: sessionOrder.compactMap { reps[$0] }, evidence: sorted,
          categories: DetectionCategory.allCases.filter { category in
            sorted.contains { $0.category == category }
          }, strongest: rows.compactMap(\.rssi).max(),
          firstSeen: rows.compactMap(\.timestamp).min(),
          lastSeen: rows.compactMap(\.timestamp).max()))
    }
    return sorted(candidates, by: .evidence)
  }
  public static func sorted(_ values: [Candidate], by sort: CandidateSort) -> [Candidate] {
    values.sorted { a, b in
      if sort == .recent {
        return a.lastSeen == b.lastSeen
          ? a.id < b.id : (a.lastSeen ?? -.infinity) > (b.lastSeen ?? -.infinity)
      }
      if sort == .evidence, a.evidence[0].rank != b.evidence[0].rank {
        return a.evidence[0].rank < b.evidence[0].rank
      }
      return a.strongest == b.strongest
        ? a.id < b.id : (a.strongest ?? -.infinity) > (b.strongest ?? -.infinity)
    }
  }
}
