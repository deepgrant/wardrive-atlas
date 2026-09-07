import SwiftUI
import WardriveAtlasCore

struct RootView: View {
  @EnvironmentObject var app: AppCoordinator
  var body: some View {
    NavigationSplitView {
      SidebarView().navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
    } detail: {
      HSplitView {
        VStack(spacing: 0) {
          HStack(spacing: 20) {
            metric("Visible", app.filtered.count.formatted())
            metric("Wi-Fi", app.filtered.filter { $0.type == .wifi }.count.formatted())
            metric("Bluetooth", app.filtered.filter { $0.type == .ble }.count.formatted())
            Spacer()
            if app.importing || app.analyzing {
              ProgressView().controlSize(.small)
              Text(app.importing ? "Importing…" : "Analyzing…").foregroundStyle(.secondary)
            }
          }.padding(16).background(.bar)
          ZStack {
            if app.streetMap { NativeMapView() } else { OfflineMapView() }
            if app.records.isEmpty {
              VStack(spacing: 16) {
                Image(systemName: "map.fill").font(.system(size: 42)).foregroundStyle(.indigo)
                Text("Your drive, in perspective").font(.title2.bold())
                Text("Explore Wi-Fi and Bluetooth observations privately on your Mac.")
                  .foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                  Button("Import CSV…") { app.openFiles() }.buttonStyle(.borderedProminent)
                  Button("Load Sample Drive") { app.loadSample() }.accessibilityIdentifier(
                    "loadSample")
                }
              }.padding(28).frame(maxWidth: 420).background(
                .regularMaterial, in: RoundedRectangle(cornerRadius: 20)
              ).shadow(radius: 12)
            }
          }
          HStack {
            Circle().fill(.red).frame(width: 7, height: 7)
            Text("Wi-Fi")
            Circle().fill(.purple).frame(width: 7, height: 7)
            Text("Bluetooth")
            Spacer()
            Text(app.streetMap ? app.mapStatus : "Offline grid · no street-map requests").lineLimit(
              2)
          }.font(.caption).foregroundStyle(.secondary).padding(10).background(.bar)
        }.frame(minWidth: 400)
        InspectorView().frame(minWidth: 260, idealWidth: 305, maxWidth: 380)
      }
    }
    .navigationTitle("Wardrive Atlas")
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button {
          app.openFiles()
        } label: {
          Label("Import CSV", systemImage: "square.and.arrow.down")
        }.help("Import CSV files (⌘O)").accessibilityIdentifier("importCSV")
        Picker("Map mode", selection: $app.mapMode) {
          ForEach(MapMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).frame(width: 220).accessibilityIdentifier("mapMode")
        Toggle(isOn: $app.streetMap) { Label("Street map", systemImage: "map") }.help(
          "Show Apple Maps street tiles"
        ).accessibilityIdentifier("streetMap")
        Toggle(isOn: $app.route) {
          Label("Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
        }.help("Show receiver observation route")
        Button {
          app.fitRevision += 1
        } label: {
          Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
        }.help("Fit observations (⌘0)")
        SettingsLink { Image(systemName: "gearshape") }.help("Settings")
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      app.importFiles(urls)
      return urls.contains { $0.pathExtension.lowercased() == "csv" }
    }
    .alert(
      "Wardrive Atlas",
      isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })
    ) {
      Button("OK") { app.error = nil }
    } message: {
      Text(app.error ?? "")
    }
  }
  private func metric(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(value).font(.title3.monospacedDigit().bold())
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }
}

struct SidebarView: View {
  @EnvironmentObject var app: AppCoordinator
  @State private var filtersExpanded = true
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack {
          Label("CAPTURES", systemImage: "tray.full").font(.caption.bold()).foregroundStyle(
            .secondary)
          Spacer()
          Button("Clear") { app.clear() }.disabled(app.records.isEmpty).accessibilityIdentifier(
            "clearCaptures")
        }
        if app.sessions.isEmpty {
          Text("No captures loaded").font(.callout).foregroundStyle(.secondary)
        }
        ForEach(app.sessions, id: \.self) { session in
          HStack {
            Toggle(
              isOn: Binding(
                get: { app.filter.sessions?.contains(session) ?? true },
                set: { value in
                  var set = app.filter.sessions ?? Set(app.sessions)
                  if value { set.insert(session) } else { set.remove(session) }
                  app.filter.sessions = set
                })
            ) { Text(session).lineLimit(1).help(session) }
            Button {
              app.removeSession(session)
            } label: {
              Image(systemName: "xmark")
            }.buttonStyle(.plain).help("Remove capture")
          }
        }
        if app.importing { Button("Cancel Import") { app.cancelImport() } }
        DisclosureGroup("Filters", isExpanded: $filtersExpanded) { FilterView() }
        Divider()
        Picker("Analysis", selection: $app.analysisPanel) {
          Text("Notable").tag("Notable")
          Text("Co-travel").tag("Co-travel")
        }.pickerStyle(.segmented).accessibilityIdentifier("analysisPanel")
        if app.analysisPanel == "Notable" { notable } else { coTravel }
        ForEach(app.settings.warnings, id: \.self) { warning in
          Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(
            .orange)
        }
        Text(app.status).font(.caption).foregroundStyle(.secondary)
      }.padding(16)
    }.background(.background)
  }
  private var notable: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle("Include research leads", isOn: $app.research)
      Picker("Category", selection: $app.category) {
        Text("All categories").tag(DetectionCategory?.none)
        ForEach(DetectionCategory.allCases, id: \.self) { category in
          Text(
            "\(category.title) · \(app.candidates.filter { $0.categories.contains(category) }.count)"
          ).tag(Optional(category))
        }
      }
      Picker("Sort", selection: $app.candidateSort) {
        ForEach(CandidateSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      if !app.dismissed.isEmpty {
        Button("Restore \(app.dismissed.count) dismissed") { app.restoreDismissed() }
      }
      Text("\(app.visibleCandidates.count) observed addresses").font(.caption).foregroundStyle(
        .secondary)
      LazyVStack(spacing: 6) {
        ForEach(app.visibleCandidates) { candidate in
          Button {
            app.selection = .candidate(candidate.key)
          } label: {
            candidateRow(
              title: candidate.representatives[0].name(app.namePrivacy),
              subtitle: candidate.categories.map(\.title).joined(separator: " · "),
              footnote:
                "\(candidate.records.count) observations · \(candidate.weak ? "Research lead" : "Candidate")",
              symbol: candidate.categories.first?.symbol ?? "mappin",
              selected: app.selection == .candidate(candidate.key))
          }.buttonStyle(.plain).accessibilityIdentifier("candidate-\(candidate.id)")
        }
      }
      if app.visibleCandidates.isEmpty {
        Text(
          "No matching evidence in this view. An empty result does not establish that no devices were present."
        ).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
  private var coTravel: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker("View", selection: $app.movementView) {
        ForEach(MovementView.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      Picker("Sensitivity", selection: $app.sensitivity) {
        ForEach(Sensitivity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
      }
      let c = app.movement.coverage
      Text("\(c.eligible) eligible · \(c.excluded) excluded · \(c.duplicates) minute repeats").font(
        .caption
      ).foregroundStyle(.secondary)
      DisclosureGroup("Evidence coverage") {
        VStack(alignment: .leading) {
          Text("Invalid address: \(c.invalidAddress)")
          Text("Missing time: \(c.invalidTime)")
          Text("Invalid position: \(c.invalidFix)")
          Text("Missing/poor accuracy: \(c.invalidAccuracy)")
          Text("\(c.independent) independent sightings · \(c.locations) per-address locations")
        }.font(.caption)
      }
      LazyVStack(spacing: 6) {
        ForEach(app.visibleMovement) { assessment in
          Button {
            app.selection = .movement(assessment.representative.candidateKey)
          } label: {
            candidateRow(
              title: assessment.representative.name(app.namePrivacy),
              subtitle: assessment.representative.address(app.addressPrivacy),
              footnote:
                "\(assessment.sightings.count) independent · \(assessment.locations) locations",
              symbol: "arrow.triangle.turn.up.right.diamond",
              selected: app.selection == .movement(assessment.representative.candidateKey))
          }.buttonStyle(.plain)
        }
        if app.movementView == .trusted {
          ForEach(app.absentTrusted) { device in
            Button {
              app.selection = .trusted(device)
            } label: {
              candidateRow(
                title: app.addressPrivacy == .hide ? "Hidden" : device.alias,
                subtitle: device.type.rawValue, footnote: "Saved device · absent from this view",
                symbol: "checkmark.shield", selected: app.selection == .trusted(device))
            }.buttonStyle(.plain)
          }
        }
      }
      Text(
        "Co-travel candidates are shared-route evidence, not confirmed surveillance. Receiver positions are not device locations."
      ).font(.caption).foregroundStyle(.secondary)
    }
  }
  private func candidateRow(
    title: String, subtitle: String, footnote: String, symbol: String, selected: Bool
  ) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: symbol).foregroundStyle(.indigo).frame(width: 20)
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.callout.bold()).lineLimit(1)
        Text(subtitle).font(.caption).lineLimit(1)
        Text(footnote).font(.caption2).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(
      selected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.07),
      in: RoundedRectangle(cornerRadius: 8))
  }
}

struct FilterView: View {
  @EnvironmentObject var app: AppCoordinator
  var body: some View {
    VStack(spacing: 10) {
      Picker("Radio", selection: $app.filter.radio) {
        Text("All").tag(Radio?.none)
        ForEach(Radio.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
      }
      Picker("Band", selection: $app.filter.band) {
        Text("All").tag(String?.none)
        ForEach(Set(app.records.map(\.band)).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
      }
      Picker("Channel", selection: $app.filter.channel) {
        Text("All").tag(Int?.none)
        ForEach(Set(app.records.compactMap(\.channel)).sorted(), id: \.self) {
          Text(String($0)).tag(Optional($0))
        }
      }
      Picker("Security", selection: $app.filter.security) {
        Text("All").tag(String?.none)
        ForEach(Set(app.records.map(\.security)).sorted(), id: \.self) {
          Text($0).tag(Optional($0))
        }
      }
      VStack(alignment: .leading) {
        Text("Minimum signal: \(Int(app.filter.minimumRSSI)) dBm").font(.caption)
        Slider(value: $app.filter.minimumRSSI, in: -127 ... -20, step: 1)
      }
      timeControl("From", keyPath: \.from)
      timeControl("To", keyPath: \.to)
      Button("Reset Filters") { app.filter = .init() }.frame(
        maxWidth: .infinity, alignment: .trailing)
    }.padding(.top, 8).controlSize(.small)
  }
  private func timeControl(_ title: String, keyPath: WritableKeyPath<ObservationFilter, Double?>)
    -> some View
  {
    VStack {
      Toggle(
        title,
        isOn: Binding(
          get: { app.filter[keyPath: keyPath] != nil },
          set: {
            app.filter[keyPath: keyPath] =
              $0
              ? (title == "From"
                ? app.records.compactMap(\.timestamp).min()
                : app.records.compactMap(\.timestamp).max()) ?? Date().timeIntervalSince1970 * 1000
              : nil
          }))
      if app.filter[keyPath: keyPath] != nil {
        DatePicker(
          title,
          selection: Binding(
            get: { Date(timeIntervalSince1970: (app.filter[keyPath: keyPath] ?? 0) / 1000) },
            set: { app.filter[keyPath: keyPath] = $0.timeIntervalSince1970 * 1000 })
        ).labelsHidden()
      }
    }
  }
}
