import SwiftUI
import WardriveAtlasCore

struct AtlasSettingsView: View {
  @EnvironmentObject var app: AppCoordinator
  @State private var prefix = ""
  @State private var category: DetectionCategory = .flock
  @State private var radio: RuleProtocol = .both
  @State private var ignored = false
  @State private var validation: String?
  var body: some View {
    TabView {
      Form {
        Section("Identifier privacy") {
          Picker("Network names", selection: $app.namePrivacy) {
            ForEach(PrivacyMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
          }
          Picker("Device addresses", selection: $app.addressPrivacy) {
            ForEach(PrivacyMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
          }
          Text(
            "Hash aliases conceal labels but are not encryption or guaranteed anonymity. Raw captures remain in memory while loaded."
          ).font(.caption).foregroundStyle(.secondary)
        }
        Section("Map") {
          Toggle("Show Apple Maps street map", isOn: $app.streetMap)
          Text(
            "Street maps contact Apple for map resources. The offline grid draws observations locally without creating an online map view. Capture files are never uploaded."
          ).font(.caption).foregroundStyle(.secondary)
        }
        Section("Local data") {
          Text("\(app.settings.savedTrust.devices.count) saved trusted identities")
          Text(
            "Captures are not automatically saved. Rules and trusted-device digests are stored in Application Support. Browser settings are not migrated automatically."
          ).font(.caption).foregroundStyle(.secondary)
        }
      }.formStyle(.grouped).tabItem { Label("Privacy", systemImage: "hand.raised") }
      VStack(alignment: .leading, spacing: 12) {
        Text("Custom detection rules").font(.title2.bold())
        Text(
          "User-defined prefixes supplement the bundled local catalog. Ignored prefixes suppress notable matching for the selected radio."
        ).font(.caption).foregroundStyle(.secondary)
        HStack {
          TextField("B4:1E:52", text: $prefix)
          Picker("Radio", selection: $radio) {
            ForEach(RuleProtocol.allCases, id: \.self) { Text($0.rawValue).tag($0) }
          }
          Toggle("Ignore", isOn: $ignored)
        }
        HStack {
          Picker("Category", selection: $category) {
            ForEach(DetectionCategory.allCases, id: \.self) { Text($0.title).tag($0) }
          }.disabled(ignored)
          Button("Add Rule") { addRule() }.disabled(app.saving || app.settings.rulesPending)
        }
        if let validation { Text(validation).font(.caption).foregroundStyle(.red) }
        List {
          ForEach(Array(app.settings.rules.custom.enumerated()), id: \.offset) { index, rule in
            HStack {
              Text("\(rule.prefix) · \(rule.category.title) · \(rule.protocol.rawValue)")
              Spacer()
              Button("Remove") {
                var settings = app.settings.rules
                settings.custom.remove(at: index)
                app.saveRules(settings)
              }.disabled(app.saving || app.settings.rulesPending)
            }
          }
          ForEach(Array(app.settings.rules.ignored.enumerated()), id: \.offset) { index, rule in
            HStack {
              Text("\(rule.prefix) · Ignored · \(rule.protocol.rawValue)")
              Spacer()
              Button("Remove") {
                var settings = app.settings.rules
                settings.ignored.remove(at: index)
                app.saveRules(settings)
              }.disabled(app.saving || app.settings.rulesPending)
            }
          }
        }
        ForEach(app.settings.ruleWarnings, id: \.self) { warning in
          Text(warning).font(.caption).foregroundStyle(.orange)
        }
        if app.settings.rulesPending {
          HStack {
            Button("Save changes") { app.saveRules(app.settings.rules, retry: true) }
            Button("Discard changes") { app.discardRules() }
          }.disabled(app.saving)
        }
        HStack {
          Button("Import Rules…") { app.importRules() }.disabled(
            app.saving || app.settings.rulesPending)
          Button("Export Rules…") { app.exportRules() }
          Spacer()
          Button("Reset Custom Rules") { app.saveRules(.init(), reset: true) }.disabled(app.saving)
        }
        Text(
          "Built-in catalog 2026-08-30.1 · source links appear with each match. Reset leaves built-in rules and trusted devices intact."
        ).font(.caption2).foregroundStyle(.secondary)
      }.padding(20).tabItem { Label("Rules", systemImage: "line.3.horizontal.decrease.circle") }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          Text("Trusted devices").font(.title2.bold())
          Text(
            "Saved entries are digest aliases. Raw addresses, names, locations, and capture rows are never stored here."
          ).font(.caption).foregroundStyle(.secondary)
          ForEach(app.settings.trustWarnings, id: \.self) { warning in
            Text(warning).font(.caption).foregroundStyle(.orange)
          }
          ForEach(app.trustedRows) { device in
            HStack {
              VStack(alignment: .leading) {
                Text(app.addressPrivacy == .hide ? "Hidden" : device.alias)
                Text(device.type.rawValue).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if let pending = app.settings.trustOverrides[device] {
                Text("Session-only").font(.caption).foregroundStyle(.orange)
                Button("Save change") { app.trust(device, pending) }
              }
              Button(app.trustedIdentities.contains(device) ? "Remove trust" : "Trust") {
                app.trust(device, !app.trustedIdentities.contains(device))
              }
            }.disabled(app.saving)
          }
        }.padding(20)
      }.tabItem { Label("Trusted", systemImage: "checkmark.shield") }
    }.padding(8)
  }
  private func addRule() {
    do {
      let value = try normalizePrefix(prefix)
      var addition = RuleSettings()
      if ignored {
        addition.ignored.append(.init(prefix: value, protocol: radio))
      } else {
        addition.custom.append(.init(prefix: value, category: category, protocol: radio))
      }
      app.saveRules(try app.settings.rules.merging(addition))
      prefix = ""
      validation = nil
    } catch { validation = error.localizedDescription }
  }
}
