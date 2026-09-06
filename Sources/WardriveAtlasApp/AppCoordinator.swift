import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WardriveAtlasCore

struct AnalysisOutput: Sendable {
  var filtered: [Observation]
  var candidates: [Candidate]
  var movement: MovementResult
}
enum Selection: Equatable {
  case observation(String)
  case candidate(String)
  case movement(String)
  case trusted(TrustedDevice)
}

@MainActor
final class AppCoordinator: ObservableObject {
  @Published var records: [Observation] = []
  @Published var filtered: [Observation] = []
  @Published var candidates: [Candidate] = []
  @Published var movement = MovementResult()
  @Published var settings = SettingsSnapshot()
  @Published var filter = ObservationFilter() { didSet { analyze() } }
  @Published var sensitivity: Sensitivity = .medium { didSet { analyze() } }
  @Published var research = false { didSet { analyze() } }
  @Published var dismissed: Set<String> = []
  @Published var selection: Selection? { didSet { refreshMap() } }
  @Published var category: DetectionCategory? {
    didSet {
      reconcileSelection()
      refreshMap()
    }
  }
  @Published var candidateSort: CandidateSort = .evidence
  @Published var movementView: MovementView = .candidates {
    didSet {
      reconcileSelection()
      refreshMap()
    }
  }
  @Published var analysisPanel = "Notable" {
    didSet {
      selection = nil
      refreshMap()
    }
  }
  @Published var mapMode: MapMode = .points
  @Published var route = false { didSet { refreshMap() } }
  @Published var streetMap = true {
    didSet {
      if started, ProcessInfo.processInfo.environment["ATLAS_SETTINGS_DIRECTORY"] == nil {
        UserDefaults.standard.set(streetMap, forKey: "streetMap")
      }
    }
  }
  @Published var namePrivacy: PrivacyMode = .show
  @Published var addressPrivacy: PrivacyMode = .show
  @Published var presentation = MapPresentation()
  @Published var presentationRevision = 0
  @Published var fitRevision = 0
  @Published var importing = false
  @Published var analyzing = false
  @Published var saving = false
  @Published var status = "Import a capture or explore the synthetic sample."
  @Published var error: String?
  @Published var mapStatus = "Apple Maps · observations stay on this Mac"
  private var catalog: RuleCatalog?
  private let store: SettingsStore
  private var started = false
  private var pendingFit = false
  private var generation = 0, importGeneration = 0, mapGeneration = 0
  private var analysisTask: Task<Void, Never>?
  private var analysisWork: Task<AnalysisOutput, Error>?
  private var importWork: Task<([Observation], [String]), Error>?
  private var mapWork: Task<MapPresentation, Error>?
  private var rowIndex: [String: Observation] = [:]
  init() {
    let args = ProcessInfo.processInfo.arguments
    if let directory = ProcessInfo.processInfo.environment["ATLAS_SETTINGS_DIRECTORY"] {
      store = SettingsStore(directory: URL(fileURLWithPath: directory))
    } else {
      store = SettingsStore()
    }
    streetMap =
      (args.contains("--offline") || ProcessInfo.processInfo.environment["ATLAS_OFFLINE"] == "1")
      ? false : UserDefaults.standard.object(forKey: "streetMap") as? Bool ?? true
  }
  func start() async {
    guard !started else { return }
    started = true
    do { catalog = try RuleCatalog.load() } catch { self.error = error.localizedDescription }
    settings = await store.load()
    let args = ProcessInfo.processInfo.arguments
    if args.contains("--sample") { loadSample() }
    if let index = args.firstIndex(of: "--import"), args.indices.contains(index + 1) {
      importFiles([URL(fileURLWithPath: args[index + 1])])
    }
    if let text = ProcessInfo.processInfo.environment["ATLAS_BENCHMARK_COUNT"],
      let count = Int(text), count > 0, count <= 100_000
    {
      records = SyntheticDrive.records(count: count)
      afterImport()
    }
  }
  var sessions: [String] { Set(records.map(\.session)).sorted() }
  var visibleCandidates: [Candidate] {
    NotableAnalysis.sorted(
      candidates.filter { category == nil || $0.categories.contains(category!) }, by: candidateSort)
  }
  var visibleMovement: [MovementAssessment] {
    movement.assessments.filter {
      $0.view(
        trusted: $0.representative.identity.map { settings.effectiveTrust.contains($0) } ?? false)
        == movementView
    }
  }
  var absentTrusted: [TrustedDevice] {
    let present = Set(movement.assessments.compactMap { $0.representative.identity })
    return settings.effectiveTrust.subtracting(present).sorted { $0.id < $1.id }
  }
  var selectedCandidate: Candidate? {
    if case .candidate(let key) = selection { return candidates.first { $0.key == key } }
    return nil
  }
  var selectedMovement: MovementAssessment? {
    if case .movement(let key) = selection {
      return movement.assessments.first { $0.representative.candidateKey == key }
    }
    return nil
  }
  var selectedRecord: Observation? {
    switch selection {
    case .observation(let id): return rowIndex[id]
    case .candidate: return selectedCandidate?.representatives.first
    case .movement: return selectedMovement?.representative
    default: return nil
    }
  }
  var selectedRecords: [Observation] {
    selectedCandidate?.records ?? selectedMovement?.records ?? selectedRecord.map { [$0] } ?? []
  }
  func reconcileSelection() {
    switch selection {
    case .candidate(let key):
      if !visibleCandidates.contains(where: { $0.key == key }) { selection = nil }
    case .movement(let key):
      if !visibleMovement.contains(where: { $0.representative.candidateKey == key }) {
        selection = nil
      }
    case .observation(let id): if !filtered.contains(where: { $0.id == id }) { selection = nil }
    default: break
    }
  }
  func openFiles() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    if panel.runModal() == .OK { importFiles(panel.urls) }
  }
  func importFiles(_ urls: [URL]) {
    let urls = urls.filter { $0.pathExtension.lowercased() == "csv" }
    guard !urls.isEmpty else {
      error = "Choose one or more CSV files."
      return
    }
    cancelImport()
    let ticket = importGeneration
    importing = true
    status = "Reading \(urls.count) capture file(s)…"
    let existing = Set(records.map(\.session))
    let work = Task.detached(priority: .userInitiated) { () throws -> ([Observation], [String]) in
      var imported: [Observation] = []
      var errors: [String] = []
      var names = existing
      for url in urls {
        try Task.checkCancellation()
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
          let name = CSVImporter.uniqueSession(url.lastPathComponent, existing: names)
          let data = try Data(contentsOf: url, options: .mappedIfSafe)
          guard let text = String(data: data, encoding: .utf8) else {
            throw AtlasError.invalid("The file is not valid UTF-8 text.")
          }
          let rows = try CSVImporter.parse(text, session: name)
          try Task.checkCancellation()
          imported.append(contentsOf: rows)
          names.insert(name)
        } catch is CancellationError { throw CancellationError() } catch {
          errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
        }
      }
      return (imported, errors)
    }
    importWork = work
    Task {
      do {
        let (rows, errors) = try await work.value
        guard ticket == importGeneration else { return }
        records.append(contentsOf: rows)
        importing = false
        importWork = nil
        status = "Imported \(rows.count.formatted()) observations."
        if !errors.isEmpty { error = errors.joined(separator: "\n") }
        if !rows.isEmpty { afterImport() }
      } catch {
        if ticket == importGeneration {
          importing = false
          status = "Import cancelled."
        }
      }
    }
  }
  func cancelImport() {
    importGeneration += 1
    importWork?.cancel()
    importWork = nil
    importing = false
  }
  func afterImport() {
    rowIndex = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    pendingFit = true
    var current = filter
    current.sessions = nil
    filter = current
  }
  func loadSample() {
    guard !records.contains(where: { $0.session == "Synthetic sample drive" }) else {
      fitRevision += 1
      return
    }
    records.append(contentsOf: SyntheticDrive.records())
    status = "Synthetic sample · no personal captures"
    afterImport()
  }
  func removeSession(_ session: String) {
    records.removeAll { $0.session == session }
    dismissed.formIntersection(Set(records.map(\.candidateKey)))
    afterImport()
  }
  func clear() {
    cancelImport()
    generation += 1
    mapGeneration += 1
    analysisTask?.cancel()
    analysisWork?.cancel()
    mapWork?.cancel()
    records = []
    rowIndex = [:]
    filtered = []
    candidates = []
    movement = .init()
    dismissed = []
    selection = nil
    presentation = .init()
    presentationRevision += 1
    filter = .init()
    analyzing = false
    status = "Captures cleared. Rules and trusted devices remain saved."
  }
  func analyze() {
    guard started, let catalog else { return }
    generation += 1
    let ticket = generation
    analysisTask?.cancel()
    analysisWork?.cancel()
    let rows = records
    let filter = filter
    let rules = settings.rules
    let sensitivity = sensitivity
    let research = research
    let dismissed = dismissed
    analyzing = !rows.isEmpty
    analysisTask = Task {
      do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
      guard ticket == generation else { return }
      let work = Task.detached(priority: .userInitiated) { () throws -> AnalysisOutput in
        let filtered = try filter.apply(rows)
        let candidates = try NotableAnalysis.analyze(
          filtered, catalog: catalog, settings: rules, research: research, dismissed: dismissed)
        let movement = try MovementAnalysis.analyze(
          filtered, catalog: catalog, sensitivity: sensitivity, custom: rules.custom)
        return AnalysisOutput(filtered: filtered, candidates: candidates, movement: movement)
      }
      analysisWork = work
      do {
        let output = try await work.value
        guard ticket == generation else { return }
        filtered = output.filtered
        candidates = output.candidates
        movement = output.movement
        analyzing = false
        reconcileSelection()
        refreshMap()
      } catch is CancellationError {} catch {
        if ticket == generation {
          analyzing = false
          self.error = error.localizedDescription
        }
      }
    }
  }
  func refreshMap() {
    mapGeneration += 1
    let ticket = mapGeneration
    mapWork?.cancel()
    let rows = filtered
    let candidates = analysisPanel == "Notable" ? visibleCandidates : []
    let assessments = analysisPanel == "Notable" ? [] : visibleMovement
    let selected = Set(selectedRecords.map(\.id))
    let selectedMovement = selectedMovement
    let route = route
    let work = Task.detached(priority: .userInitiated) {
      try MapPresentation.make(
        records: rows, candidates: candidates, movement: assessments, selectedIDs: selected,
        selectedMovement: selectedMovement, route: route)
    }
    mapWork = work
    Task {
      do {
        let result = try await work.value
        guard ticket == mapGeneration else { return }
        presentation = result
        presentationRevision += 1
        if pendingFit {
          pendingFit = false
          fitRevision += 1
        }
      } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
  }
  func selectMap(_ id: String) {
    let base = String(id.split(separator: "/")[0])
    if let candidate = candidates.first(where: { $0.id == base }) {
      selection = .candidate(candidate.key)
    } else if let assessment = movement.assessments.first(where: { $0.id == base }) {
      selection = .movement(assessment.representative.candidateKey)
    } else {
      selection = .observation(id)
    }
  }
  func dismissCandidate() {
    if let candidate = selectedCandidate {
      dismissed.insert(candidate.key)
      selection = nil
      analyze()
    }
  }
  func restoreDismissed() {
    dismissed = []
    analyze()
  }
  func trust(_ device: TrustedDevice, _ value: Bool) {
    guard !saving else { return }
    saving = true
    Task {
      settings = await store.updateTrust(device, trusted: value)
      saving = false
      reconcileSelection()
      refreshMap()
    }
  }
  func saveRules(_ value: RuleSettings, retry: Bool = false, reset: Bool = false) {
    guard !saving else { return }
    saving = true
    Task {
      settings = await store.updateRules(value, explicitRetry: retry, reset: reset)
      saving = false
      analyze()
    }
  }
  func discardRules() {
    Task {
      settings = await store.discardPendingRules()
      analyze()
    }
  }
  func importRules() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let rules = try RuleSettings.parse(Data(contentsOf: url))
      saveRules(try settings.rules.merging(rules))
    } catch { self.error = error.localizedDescription }
  }
  func exportRules() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "wardrive-atlas-rules.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(settings.rules).write(to: url, options: .atomic)
    } catch { self.error = error.localizedDescription }
  }
}
