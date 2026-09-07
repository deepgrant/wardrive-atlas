import Foundation
import Testing

@testable import WardriveAtlasCore

private final class WriteControl: @unchecked Sendable {
  private let lock = NSLock()
  private var failure = false
  func fail(_ value: Bool) {
    lock.lock()
    failure = value
    lock.unlock()
  }
  func write(_ data: Data, _ url: URL) throws {
    lock.lock()
    let denied = failure
    lock.unlock()
    if denied { throw CocoaError(.fileWriteNoPermission) }
    try data.write(to: url, options: .atomic)
  }
}
struct SettingsTests {
  func directory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("atlas-test-\(UUID().uuidString)")
  }
  @Test func digestsAndLabels() {
    var a = row()
    var b = a
    b.bssid = "da-10-20-30-40-50"
    #expect(a.identity == b.identity)
    #expect(a.identity?.digest.count == 64)
    b.type = .wifi
    #expect(a.identity != b.identity)
    #expect(a.name(.hide) == "Private network")
    #expect(!a.name(.hash).contains(a.ssid))
    #expect(a.address(.hide) == "Hidden")
    #expect(a.address(.show) == a.bssid)
    #expect(a.identity?.alias == "Saved device \(a.identity!.digest.prefix(12))")
    #expect(a.identity?.digest == sha256("wardrive-atlas:co-travel:v1|BLE|DA1020304050"))
    a.bssid = "unknown"
    #expect(a.identity == nil)
  }
  @Test func concurrentTrustAndUntrust() async throws {
    let url = directory()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = SettingsStore(directory: url)
    let devices = (0..<40).map { TrustedDevice(digest: sha256("device-\($0)"), type: .ble) }
    await withTaskGroup(of: Void.self) { group in
      for device in devices { group.addTask { _ = await store.updateTrust(device, trusted: true) } }
    }
    #expect(await store.load().effectiveTrust.count == 40)
    _ = await store.updateTrust(devices[0], trusted: false)
    _ = await store.updateTrust(TrustedDevice(digest: sha256("new"), type: .wifi), trusted: true)
    #expect(await !store.load().effectiveTrust.contains(devices[0]))
    let reloaded = await SettingsStore(directory: url).load()
    #expect(reloaded.effectiveTrust.count == 40)
    #expect(!reloaded.effectiveTrust.contains(devices[0]))
    let text = try String(contentsOf: url.appendingPathComponent("trust-v1.json"), encoding: .utf8)
    #expect(!text.contains("Synthetic"))
    #expect(!text.contains("latitude"))
    #expect(!text.contains("bssid"))
  }
  @Test func failedSaveDoesNotPersistOnUnrelatedSuccess() async throws {
    let url = directory()
    defer { try? FileManager.default.removeItem(at: url) }
    let control = WriteControl()
    let a = TrustedDevice(digest: sha256("a"), type: .ble)
    let b = TrustedDevice(digest: sha256("b"), type: .ble)
    let store = SettingsStore(directory: url, writer: { try control.write($0, $1) })
    control.fail(true)
    let failed = await store.updateTrust(a, trusted: true)
    #expect(failed.effectiveTrust.contains(a))
    #expect(failed.savedTrust.devices.isEmpty)
    #expect(failed.trustOverrides[a] == true)
    control.fail(false)
    let success = await store.updateTrust(b, trusted: true)
    #expect(success.effectiveTrust.contains(a))
    #expect(!success.savedTrust.devices.contains(a))
    #expect(success.savedTrust.devices.contains(b))
    #expect(await !SettingsStore(directory: url).load().effectiveTrust.contains(a))
    let retried = await store.updateTrust(a, trusted: true)
    #expect(retried.trustOverrides[a] == nil)
    #expect(retried.savedTrust.devices.contains(a))
    control.fail(true)
    _ = await store.updateTrust(a, trusted: false)
    control.fail(false)
    let unrelated = await store.updateTrust(b, trusted: false)
    #expect(!unrelated.effectiveTrust.contains(a))
    #expect(unrelated.savedTrust.devices.contains(a))
    #expect(await SettingsStore(directory: url).load().effectiveTrust.contains(a))
  }
  @Test func invalidFilesAreNotOverwritten() async throws {
    let url = directory()
    defer { try? FileManager.default.removeItem(at: url) }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let file = url.appendingPathComponent("trust-v1.json")
    let invalid = Data("broken".utf8)
    try invalid.write(to: file)
    let store = SettingsStore(directory: url)
    let state = await store.updateTrust(
      TrustedDevice(digest: sha256("a"), type: .ble), trusted: true)
    #expect(state.savedTrust.devices.isEmpty)
    #expect(state.trustOverrides.count == 1)
    #expect(try Data(contentsOf: file) == invalid)
  }
  @Test func corruptionAfterLoadDoesNotKeepStaleSavedTrust() async throws {
    let url = directory()
    defer { try? FileManager.default.removeItem(at: url) }
    let store = SettingsStore(directory: url)
    let a = TrustedDevice(digest: sha256("a"), type: .ble)
    let b = TrustedDevice(digest: sha256("b"), type: .ble)
    _ = await store.updateTrust(a, trusted: true)
    let file = url.appendingPathComponent("trust-v1.json")
    try Data("corrupted".utf8).write(to: file, options: .atomic)
    let state = await store.updateTrust(b, trusted: true)
    #expect(state.savedTrust.devices.isEmpty)
    #expect(!state.effectiveTrust.contains(a))
    #expect(state.trustOverrides[b] == true)
    #expect(try String(contentsOf: file, encoding: .utf8) == "corrupted")
  }
  @Test func rulesSaveRetryResetAndIsolation() async throws {
    let url = directory()
    defer { try? FileManager.default.removeItem(at: url) }
    let control = WriteControl()
    let store = SettingsStore(directory: url, writer: { try control.write($0, $1) })
    let device = TrustedDevice(digest: sha256("trusted"), type: .ble)
    _ = await store.updateTrust(device, trusted: true)
    var rules = RuleSettings()
    rules.custom = [.init(prefix: "B41E52", category: .flock, protocol: .both)]
    control.fail(true)
    let failed = await store.updateRules(rules)
    #expect(failed.rulesPending)
    control.fail(false)
    let blocked = await store.updateRules(.init())
    #expect(blocked.rules == rules)
    #expect(blocked.rulesPending)
    let saved = await store.updateRules(rules, explicitRetry: true)
    #expect(!saved.rulesPending)
    #expect(await SettingsStore(directory: url).load().rules == rules)
    let reset = await store.updateRules(.init(), reset: true)
    #expect(reset.rules.custom.isEmpty)
    #expect(reset.effectiveTrust.contains(device))
  }
  @Test func strictValidationAndLimitContention() async throws {
    var saved = TrustedSettings()
    saved.devices = (0..<10_000).map { .init(digest: sha256("\($0)"), type: .ble) }
    let url = directory()
    defer { try? FileManager.default.removeItem(at: url) }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try JSONEncoder().encode(saved).write(to: url.appendingPathComponent("trust-v1.json"))
    let store = SettingsStore(directory: url)
    let new = TrustedDevice(digest: sha256("new"), type: .ble)
    let full = await store.updateTrust(new, trusted: true)
    #expect(full.savedTrust.devices.count == 10_000)
    #expect(!full.effectiveTrust.contains(new))
    #expect(full.trustOverrides.isEmpty)
    _ = await store.updateTrust(saved.devices[0], trusted: false)
    let replacement = await store.updateTrust(new, trusted: true)
    #expect(replacement.savedTrust.devices.contains(new))
    #expect(replacement.trustOverrides.isEmpty)
    let reloaded = await SettingsStore(directory: url).load()
    #expect(reloaded.effectiveTrust.count == 10_000)
    #expect(reloaded.effectiveTrust.contains(new))
    saved.devices.append(saved.devices[0])
    #expect(throws: (any Error).self) { try TrustedSettings.parse(JSONEncoder().encode(saved)) }
    #expect(throws: (any Error).self) {
      try TrustedSettings.parse(
        Data(#"{"version":1,"devices":[{"digest":"abc","type":"BLE"}]}"#.utf8))
    }
  }
}

extension SettingsTests {
  @Test func independentWarningsSurviveUnrelatedSavesAndPartialRetries() async throws {
    let url = directory()
    defer { try? FileManager.default.removeItem(at: url) }
    let control = WriteControl()
    let store = SettingsStore(directory: url, writer: { try control.write($0, $1) })
    let a = TrustedDevice(digest: sha256("warning-a"), type: .ble)
    let b = TrustedDevice(digest: sha256("warning-b"), type: .ble)
    var rules = RuleSettings()
    rules.custom = [.init(prefix: "B41E52", category: .flock, protocol: .both)]
    control.fail(true)
    _ = await store.updateRules(rules)
    control.fail(false)
    let trusted = await store.updateTrust(a, trusted: true)
    #expect(trusted.rulesPending)
    #expect(!trusted.ruleWarnings.isEmpty)
    #expect(trusted.trustWarnings.isEmpty)
    control.fail(true)
    _ = await store.updateTrust(a, trusted: false)
    _ = await store.updateTrust(b, trusted: true)
    control.fail(false)
    let savedRules = await store.updateRules(rules, explicitRetry: true)
    #expect(savedRules.ruleWarnings.isEmpty)
    #expect(!savedRules.trustWarnings.isEmpty)
    #expect(savedRules.savedTrust.devices.contains(a))
    #expect(!savedRules.savedTrust.devices.contains(b))
    let discarded = await store.discardPendingRules()
    #expect(!discarded.trustWarnings.isEmpty)
    let partial = await store.updateTrust(a, trusted: false)
    #expect(!partial.trustWarnings.isEmpty)
    #expect(partial.trustOverrides[b] == true)
    let complete = await store.updateTrust(b, trusted: true)
    #expect(complete.warnings.isEmpty)
  }

  @Test func corruptFileWarningsSurviveUnrelatedResetAndDiscard() async throws {
    let url = directory()
    defer { try? FileManager.default.removeItem(at: url) }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let invalid = Data("invalid".utf8)
    try invalid.write(to: url.appendingPathComponent("rules-v1.json"))
    try invalid.write(to: url.appendingPathComponent("trust-v1.json"))
    let store = SettingsStore(directory: url)
    let loaded = await store.load()
    #expect(loaded.warnings == loaded.ruleWarnings + loaded.trustWarnings)
    #expect(loaded.ruleWarnings.count == 1 && loaded.trustWarnings.count == 1)
    let discarded = await store.discardPendingRules()
    #expect(discarded.ruleIssues.unreadableFile)
    #expect(discarded.trustIssues.unreadableFile)
    let reset = await store.updateRules(.init(), reset: true)
    #expect(reset.ruleWarnings.isEmpty)
    #expect(reset.trustIssues.unreadableFile)
    #expect(try Data(contentsOf: url.appendingPathComponent("trust-v1.json")) == invalid)
  }

  @Test func trustCapacityWarningRequiresSpaceToBeFreed() async throws {
    let url = directory()
    defer { try? FileManager.default.removeItem(at: url) }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    var trust = TrustedSettings()
    trust.devices = (0..<10_000).map { .init(digest: sha256("capacity-\($0)"), type: .ble) }
    try JSONEncoder().encode(trust).write(to: url.appendingPathComponent("trust-v1.json"))
    let store = SettingsStore(directory: url)
    let failed = await store.updateTrust(.init(digest: sha256("extra"), type: .ble), trusted: true)
    #expect(failed.trustIssues.capacityReached)
    let rulesSaved = await store.updateRules(.init())
    #expect(rulesSaved.trustIssues.capacityReached)
    let existing = await store.updateTrust(trust.devices[0], trusted: true)
    #expect(existing.trustIssues.capacityReached)
    let removed = await store.updateTrust(trust.devices[0], trusted: false)
    #expect(!removed.trustIssues.capacityReached)
  }
}
