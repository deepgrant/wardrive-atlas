import Foundation

public struct TrustedDevice: Codable, Hashable, Identifiable, Sendable {
  public var digest: String
  public var type: Radio
  public var id: String { "\(type.rawValue):\(digest)" }
  public init(digest: String, type: Radio) {
    self.digest = digest
    self.type = type
  }
  public var alias: String { "Saved device \(digest.prefix(12))" }
}
public struct TrustedSettings: Codable, Equatable, Sendable {
  public var version = 1
  public var devices: [TrustedDevice] = []
  public init() {}
  public static func parse(_ data: Data) throws -> Self {
    guard data.count <= 2_000_000 else {
      throw AtlasError.invalid("Oversized trusted-device settings.")
    }
    let object = try JSONSerialization.jsonObject(with: data)
    try validateKeys(object, keys: ["version", "devices"])
    if let object = object as? [String: Any] {
      for item in object["devices"] as? [Any] ?? [] {
        try validateKeys(item, keys: ["digest", "type"])
      }
    }
    let settings = try JSONDecoder().decode(Self.self, from: data)
    guard settings.version == 1, settings.devices.count <= 10_000,
      Set(settings.devices).count == settings.devices.count,
      settings.devices.allSatisfy({
        $0.digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
      })
    else {
      throw AtlasError.invalid("Invalid trusted-device settings or more than 10,000 entries.")
    }
    return settings
  }
}
public struct RuleIssueState: Sendable {
  public var unreadableFile = false
  public var invalidChange: String?
  public init() {}
}
public struct TrustIssueState: Sendable {
  public var unreadableFile = false
  public var capacityReached = false
  public init() {}
}
public struct SettingsSnapshot: Sendable {
  public var rules = RuleSettings()
  public var savedTrust = TrustedSettings()
  public var trustOverrides: [TrustedDevice: Bool] = [:]
  public var rulesPending = false
  public var ruleIssues = RuleIssueState()
  public var trustIssues = TrustIssueState()
  public init() {}
  public var ruleWarnings: [String] {
    var messages: [String] = []
    if ruleIssues.unreadableFile {
      messages.append(
        "Saved rules could not be read. Reset Custom Rules to replace the invalid file.")
    }
    if let invalid = ruleIssues.invalidChange { messages.append(invalid) }
    if rulesPending {
      messages.append(
        "Rule changes are session-only. Save changes to retry, or discard them to restore saved rules."
      )
    }
    return messages
  }
  public var trustWarnings: [String] {
    var messages: [String] = []
    if trustIssues.unreadableFile {
      messages.append(
        "Saved trusted devices could not be read. No saved trust is active; the invalid file will not be overwritten."
      )
    }
    if trustIssues.capacityReached {
      messages.append(
        "The saved trusted-device list is full. Remove an entry before adding another.")
    }
    if !trustOverrides.isEmpty {
      messages.append(
        "Trust changes remain session-only. Save each change explicitly to retry; quitting discards unsaved changes."
      )
    }
    return messages
  }
  public var warnings: [String] { ruleWarnings + trustWarnings }
  public var effectiveTrust: Set<TrustedDevice> {
    var devices = Set(savedTrust.devices)
    for (device, trusted) in trustOverrides {
      if trusted { devices.insert(device) } else { devices.remove(device) }
    }
    return devices
  }
}

/// One app-wide owner serializes atomic file updates. There are no raw captures in these files.
public actor SettingsStore {
  public typealias Writer = @Sendable (Data, URL) throws -> Void
  private let directory: URL
  private let writer: Writer
  private var snapshot = SettingsSnapshot()
  private var loaded = false
  public init(
    directory: URL? = nil, writer: @escaping Writer = { try $0.write(to: $1, options: .atomic) }
  ) {
    self.directory =
      directory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("com.deepgrant.WardriveAtlas", isDirectory: true)
    self.writer = writer
  }
  private var rulesURL: URL { directory.appendingPathComponent("rules-v1.json") }
  private var trustURL: URL { directory.appendingPathComponent("trust-v1.json") }
  private func readTrust() throws -> TrustedSettings {
    if !FileManager.default.fileExists(atPath: trustURL.path) { return .init() }
    return try TrustedSettings.parse(Data(contentsOf: trustURL))
  }
  public func load() -> SettingsSnapshot {
    guard !loaded else { return snapshot }
    loaded = true
    do {
      if FileManager.default.fileExists(atPath: rulesURL.path) {
        snapshot.rules = try RuleSettings.parse(Data(contentsOf: rulesURL))
      }
    } catch { snapshot.ruleIssues.unreadableFile = true }
    do { snapshot.savedTrust = try readTrust() } catch {
      snapshot.trustIssues.unreadableFile = true
    }
    return snapshot
  }
  private func write<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try writer(encoder.encode(value), url)
  }
  public func updateTrust(_ device: TrustedDevice, trusted: Bool) -> SettingsSnapshot {
    _ = load()
    do {
      var latest: TrustedSettings
      do {
        latest = try readTrust()
        snapshot.savedTrust = latest
        snapshot.trustIssues.unreadableFile = false
        if latest.devices.count < 10_000 { snapshot.trustIssues.capacityReached = false }
      } catch {
        snapshot.trustIssues.unreadableFile = true
        snapshot.savedTrust = .init()
        throw error
      }
      if trusted {
        if !latest.devices.contains(device) { latest.devices.append(device) }
      } else {
        latest.devices.removeAll { $0 == device }
      }
      guard latest.devices.count <= 10_000 else {
        snapshot.trustIssues.capacityReached = true
        return snapshot
      }
      _ = try TrustedSettings.parse(JSONEncoder().encode(latest))
      try write(latest, to: trustURL)
      snapshot.savedTrust = latest
      snapshot.trustOverrides.removeValue(forKey: device)
      if latest.devices.count < 10_000 { snapshot.trustIssues.capacityReached = false }
    } catch {
      snapshot.trustOverrides[device] = trusted
    }
    return snapshot
  }
  public func updateRules(
    _ settings: RuleSettings, explicitRetry: Bool = false, reset: Bool = false
  ) -> SettingsSnapshot {
    _ = load()
    if snapshot.rulesPending && !explicitRetry && !reset { return snapshot }
    let validated: RuleSettings
    do {
      validated = try RuleSettings.parse(JSONEncoder().encode(settings))
    } catch {
      snapshot.ruleIssues.invalidChange = error.localizedDescription
      return snapshot
    }
    snapshot.rules = validated
    snapshot.ruleIssues.invalidChange = nil
    do {
      guard !snapshot.ruleIssues.unreadableFile || reset else {
        throw AtlasError.invalid("Invalid saved rule file.")
      }
      try write(validated, to: rulesURL)
      snapshot.rulesPending = false
      snapshot.ruleIssues.unreadableFile = false
    } catch {
      snapshot.rulesPending = true
    }
    return snapshot
  }
  public func discardPendingRules() -> SettingsSnapshot {
    _ = load()
    do {
      snapshot.rules =
        FileManager.default.fileExists(atPath: rulesURL.path)
        ? try RuleSettings.parse(Data(contentsOf: rulesURL)) : .init()
      snapshot.ruleIssues.unreadableFile = false
    } catch {
      snapshot.rules = .init()
      snapshot.ruleIssues.unreadableFile = true
    }
    snapshot.rulesPending = false
    snapshot.ruleIssues.invalidChange = nil
    return snapshot
  }
}
