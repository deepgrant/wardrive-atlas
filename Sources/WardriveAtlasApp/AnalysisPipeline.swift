import Foundation
import WardriveAtlasCore

struct AnalysisInput: Sendable {
  var records: [Observation]
  var filter: ObservationFilter
  var catalog: RuleCatalog
  var rules: RuleSettings
  var sensitivity: Sensitivity
  var research: Bool
  var dismissed: Set<String>

  func run() throws -> AnalysisOutput {
    let filtered = try filter.apply(records)
    return try AnalysisOutput(
      filtered: filtered,
      candidates: NotableAnalysis.analyze(
        filtered, catalog: catalog, settings: rules, research: research, dismissed: dismissed),
      movement: MovementAnalysis.analyze(
        filtered, catalog: catalog, sensitivity: sensitivity, custom: rules.custom))
  }
}

struct AnalysisOutput: Sendable {
  var filtered: [Observation]
  var candidates: [Candidate]
  var movement: MovementResult
}

enum Selection: Equatable, Sendable {
  case observation(String)
  case candidate(String)
  case movement(String)
  case trusted(TrustedDevice)
}

/// Only the presentation reaches map views. Identity-bearing selections stay with app state.
struct MapProjection: Sendable {
  var presentation = MapPresentation()
  var selections: [String: Selection] = [:]
}

struct ProjectionInput: Sendable {
  var records: [Observation]
  var candidates: [Candidate]
  var assessments: [MovementAssessment]
  var selectedIDs: Set<String>
  var selectedMovement: MovementAssessment?
  var route: Bool

  func run() throws -> MapProjection {
    let presentation = try MapPresentation.make(
      records: records, candidates: candidates, movement: assessments,
      selectedIDs: selectedIDs, selectedMovement: selectedMovement, route: route)
    var selections: [String: Selection] = [:]
    for (index, row) in records.enumerated() {
      if index % 512 == 0 { try Task.checkCancellation() }
      selections[row.id] = .observation(row.id)
    }
    for candidate in candidates {
      try Task.checkCancellation()
      for index in candidate.representatives.indices {
        selections[MapPresentation.pinID(candidate.id, index: index)] = .candidate(candidate.key)
      }
    }
    for assessment in assessments {
      try Task.checkCancellation()
      let sessionCount = Set(assessment.sightings.map { $0.record.session }).count
      for index in 0..<sessionCount {
        selections[MapPresentation.pinID(assessment.id, index: index)] =
          .movement(assessment.representative.candidateKey)
      }
    }
    return MapProjection(presentation: presentation, selections: selections)
  }
}
