import Charts
import SwiftUI
import WardriveAtlasCore

struct InspectorView: View {
  @EnvironmentObject var app: AppCoordinator
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Text("INSPECTOR").font(.caption.bold()).foregroundStyle(.secondary)
          Spacer()
          if app.selection != nil {
            Button {
              app.selection = nil
            } label: {
              Image(systemName: "xmark")
            }.buttonStyle(.plain)
          }
        }
        if let row = app.selectedRecord {
          Text(row.name(app.namePrivacy)).font(.title2.bold()).textSelection(.enabled)
          Text(row.address(app.addressPrivacy)).font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
          Label("Observed here", systemImage: "location.circle").foregroundStyle(.indigo)
          Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            detail("Radio", row.type.rawValue)
            detail("Session", row.session)
            detail("Signal", row.rssi.map { "\(scalar($0)) dBm" } ?? "Unavailable")
            detail("Band", row.band)
            detail("Channel", row.channel.map(String.init) ?? "Unavailable")
            detail("Security", row.security)
            detail(
              "Time",
              row.timestamp.map { Date(timeIntervalSince1970: $0 / 1000).formatted() }
                ?? "Unavailable")
            detail("Position", String(format: "%.5f, %.5f", row.latitude, row.longitude))
            detail("Accuracy", row.accuracy.map { "\(scalar($0)) m" } ?? "Unavailable")
            detail("Altitude", row.altitude.map { "\(scalar($0)) m" } ?? "Unavailable")
            detail("Manufacturer", row.manufacturerId ?? "Unavailable")
          }.font(.caption)
          if let candidate = app.selectedCandidate {
            Divider()
            Text("Why it was flagged").font(.headline)
            Text(
              "\(candidate.records.count) observations across \(candidate.representatives.count) sessions"
            ).font(.caption).foregroundStyle(.secondary)
            ForEach(candidate.evidence) { evidence in
              VStack(alignment: .leading, spacing: 5) {
                Text("\(evidence.category.title) · \(evidence.label)").font(.callout.bold())
                Text(evidence.explanation).font(.caption)
                if let source = evidence.source, let url = URL(string: source) {
                  Link(evidence.sourceLabel, destination: url).font(.caption)
                }
              }
            }
            Button("Dismiss candidate for this session") { app.dismissCandidate() }
          }
          if let assessment = app.selectedMovement { movementDetails(assessment) }
          if let identity = row.identity { trustControls(identity) }
          Divider()
          Text(
            "Positions show where the receiver observed a signal, not a device's estimated location. Signal strength is not a calibrated distance measurement."
          ).font(.caption).foregroundStyle(.secondary)
        } else if case .trusted(let device) = app.selection {
          Text(app.addressPrivacy == .hide ? "Hidden" : device.alias).font(.title2.bold())
          Text("\(device.type.rawValue) · absent from this capture view").foregroundStyle(
            .secondary)
          trustControls(device)
        } else {
          Image(systemName: "viewfinder.circle").font(.system(size: 38)).foregroundStyle(.tertiary)
            .padding(.top, 30)
          Text("Inspect an observation").font(.headline)
          Text("Select a point on the map or a result in the sidebar to explore the evidence.")
            .foregroundStyle(.secondary)
          Divider()
          Text("Local by design").font(.headline)
          Text(
            "Captures remain in memory. Only custom rules and trusted-device digests are saved. Apple Maps requests street-map resources when enabled."
          ).font(.callout).foregroundStyle(.secondary)
        }
      }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
    }.background(.background).accessibilityIdentifier("inspector")
  }
  private func scalar(_ value: Double) -> String {
    abs(value) >= 1_000_000_000
      ? value.formatted(.number.notation(.scientific).precision(.significantDigits(1...4)))
      : value.formatted(.number.precision(.fractionLength(0)))
  }
  private func detail(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary)
      Text(value).textSelection(.enabled)
    }
  }
  @ViewBuilder private func trustControls(_ device: TrustedDevice) -> some View {
    let trusted = app.settings.effectiveTrust.contains(device)
    Button(trusted ? "Remove trust" : "Mark as trusted") { app.trust(device, !trusted) }.disabled(
      app.saving)
    if let pending = app.settings.trustOverrides[device] {
      Label(
        "Session-only \(pending ? "trust" : "removal")", systemImage: "exclamationmark.triangle"
      ).font(.caption).foregroundStyle(.orange)
      Button("Save change") { app.trust(device, pending) }.disabled(app.saving)
    }
  }
  @ViewBuilder private func movementDetails(_ assessment: MovementAssessment) -> some View {
    Divider()
    Text(
      assessment.window?.qualifies == true
        ? "Co-travel candidate"
        : assessment.context != nil ? "Context observation" : "Observed address"
    ).font(.headline)
    Text(
      "Whole selected range: \(assessment.records.count) observations, \(assessment.sessions) sessions, \(assessment.sightings.count) independent sightings, \(assessment.locations) locations."
    ).font(.caption)
    if let window = assessment.window {
      Text("Strongest 12-hour window").font(.subheadline.bold())
      let t = app.sensitivity.thresholds
      threshold(
        "Independent sightings", Double(window.sightingIds.count), Double(t.sightings), unit: "")
      threshold("Separated locations", Double(window.locations), Double(t.locations), unit: "")
      threshold("Elapsed", (window.last - window.first) / 60_000, t.minutes, unit: "min")
      threshold("Conservative travel span", window.travelMeters, t.meters, unit: "m")
      Text(
        "\(Date(timeIntervalSince1970: window.first / 1000).formatted()) – \(Date(timeIntervalSince1970: window.last / 1000).formatted())"
      ).font(.caption2).foregroundStyle(.secondary)
    } else {
      Text("Insufficient usable time, position, accuracy, or address evidence.").font(.caption)
        .foregroundStyle(.secondary)
    }
    if let context = assessment.context {
      Text(
        context == "wifi"
          ? "Wi-Fi addresses are context and are not movement candidates."
          : "Camera-signature context: \(assessment.contextLabels.map(\.title).joined(separator: ", ")). This does not prove fixed infrastructure."
      ).font(.caption)
    }
    let history = assessment.records.filter { $0.timestamp != nil && $0.rssi != nil }
    if !history.isEmpty {
      Text("Signal history").font(.subheadline.bold())
      Chart(history) { row in
        PointMark(
          x: .value("Time", Date(timeIntervalSince1970: row.timestamp! / 1000)),
          y: .value("RSSI", row.rssi!)
        ).foregroundStyle(.indigo)
      }.chartYScale(domain: -127...0).frame(height: 140).accessibilityLabel("Signal history in dBm")
    }
    DisclosureGroup("Independent-sighting timeline") {
      LazyVStack(alignment: .leading, spacing: 8) {
        ForEach(assessment.sightings, id: \.record.id) { sighting in
          Text(
            "\(Date(timeIntervalSince1970: sighting.record.timestamp! / 1000).formatted()) · location \(sighting.location + 1)"
          ).font(.caption)
        }
      }
    }
    Text(
      "Shared routes and your own equipment can qualify. Empty results cannot establish that nothing traveled with the recorder."
    ).font(.caption).foregroundStyle(.secondary)
  }
  private func threshold(_ title: String, _ value: Double, _ required: Double, unit: String)
    -> some View
  {
    HStack(alignment: .top) {
      Image(systemName: value + 1e-6 >= required ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(value + 1e-6 >= required ? .green : .secondary)
      Text(
        "\(title): \(value.formatted(.number.precision(.fractionLength(0...1)))) / \(Int(required)) \(unit)"
      ).font(.caption)
    }
  }
}
