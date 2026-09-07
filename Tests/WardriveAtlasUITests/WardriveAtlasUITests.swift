import CryptoKit
import XCTest

final class WardriveAtlasUITests: XCTestCase {
  private var application: XCUIApplication!
  private var settingsDirectory: URL!
  override func setUpWithError() throws {
    continueAfterFailure = false
    application = XCUIApplication()
    // The shared scheme isolates hosted unit tests; this child runs normal UI startup.
    application.launchEnvironment["ATLAS_APP_TESTS"] = "0"
    application.launchEnvironment["ATLAS_OFFLINE"] = "1"
    settingsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "atlas-ui-\(UUID().uuidString)")
    application.launchEnvironment["ATLAS_SETTINGS_DIRECTORY"] = settingsDirectory.path
    application.launch()
    _ = application.windows.firstMatch.waitForExistence(timeout: 10)
  }
  override func tearDownWithError() throws {
    application.terminate()
    try? FileManager.default.removeItem(at: settingsDirectory)
  }

  private func selectControl(_ label: String) {
    let control =
      application.buttons[label].exists
      ? application.buttons[label] : application.radioButtons[label]
    XCTAssertTrue(control.waitForExistence(timeout: 10))
    control.click()
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: application.windows.firstMatch.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testOfflineHeatmapPanAndZoom() throws {
    application.buttons["loadSample"].click()
    XCTAssertTrue(application.staticTexts["240"].firstMatch.waitForExistence(timeout: 20))
    selectControl("Heatmap")
    let grid = application.descendants(matching: .any)["offlineGrid"].firstMatch
    XCTAssertTrue(grid.waitForExistence(timeout: 10))
    capture("Offline heatmap before pan")
    grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
      forDuration: 0.2,
      thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.65)))
    capture("Offline heatmap after pan")
    application.buttons["gridZoomIn"].click()
    capture("Offline heatmap after zoom")
    application.buttons["gridZoomOut"].click()
    application.typeKey("0", modifierFlags: .command)
    XCTAssertTrue(application.staticTexts["240"].firstMatch.exists)
  }

  func testSettingsShowIndependentWarnings() throws {
    application.terminate()
    try FileManager.default.createDirectory(
      at: settingsDirectory, withIntermediateDirectories: true)
    for name in ["rules-v1.json", "trust-v1.json"] {
      try Data("invalid".utf8).write(to: settingsDirectory.appendingPathComponent(name))
    }
    application.launch()
    let rulesWarning =
      "Saved rules could not be read. Reset Custom Rules to replace the invalid file."
    let trustWarning =
      "Saved trusted devices could not be read. No saved trust is active; the invalid file will not be overwritten."
    XCTAssertTrue(application.staticTexts[rulesWarning].firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue(application.staticTexts[trustWarning].firstMatch.exists)
    application.typeKey(",", modifierFlags: .command)
    selectControl("Rules")
    let rulesWindow = application.windows.containing(
      .staticText, identifier: "Custom detection rules"
    ).firstMatch
    XCTAssertTrue(rulesWindow.staticTexts[rulesWarning].waitForExistence(timeout: 10))
    selectControl("Trusted")
    let trustWindow = application.windows.containing(.staticText, identifier: "Trusted devices")
      .firstMatch
    XCTAssertTrue(trustWindow.staticTexts[trustWarning].waitForExistence(timeout: 10))
  }
  func testSampleModesSelectionAndClear() throws {
    let sample = application.buttons["loadSample"]
    XCTAssertTrue(sample.waitForExistence(timeout: 15))
    sample.click()
    XCTAssertTrue(application.staticTexts["240"].firstMatch.waitForExistence(timeout: 20))
    let hierarchy = XCTAttachment(string: application.debugDescription)
    hierarchy.lifetime = .keepAlways
    add(hierarchy)
    let initial = XCTAttachment(screenshot: application.windows.firstMatch.screenshot())
    initial.lifetime = .keepAlways
    add(initial)
    for label in ["Clusters", "Heatmap", "Points"] {
      let control =
        application.buttons[label].exists
        ? application.buttons[label] : application.radioButtons[label]
      XCTAssertTrue(control.exists)
      control.click()
    }
    let capture = application.checkBoxes["Synthetic sample drive"]
    XCTAssertTrue(capture.exists)
    capture.click()
    XCTAssertTrue(application.staticTexts["0"].firstMatch.waitForExistence(timeout: 10))
    capture.click()
    XCTAssertTrue(application.staticTexts["240"].firstMatch.waitForExistence(timeout: 10))
    let candidate = application.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "candidate-")
    ).firstMatch
    XCTAssertTrue(candidate.waitForExistence(timeout: 5))
    candidate.click()
    XCTAssertTrue(application.staticTexts["Why it was flagged"].waitForExistence(timeout: 5))
    let screenshot = XCTAttachment(screenshot: application.windows.firstMatch.screenshot())
    screenshot.lifetime = .keepAlways
    add(screenshot)
    application.buttons["clearCaptures"].click()
    XCTAssertTrue(sample.waitForExistence(timeout: 10))
  }
  func testNativeSettingsAndPrivacy() throws {
    XCTAssertTrue(application.buttons["loadSample"].waitForExistence(timeout: 15))
    application.buttons["loadSample"].click()
    application.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(application.windows.count >= 2)
    selectControl("Privacy")
    XCTAssertTrue(application.staticTexts["Identifier privacy"].waitForExistence(timeout: 8))
  }

  func testMovementInspectorTrustsTheSelectedIdentity() throws {
    application.buttons["loadSample"].click()
    XCTAssertTrue(application.staticTexts["240"].firstMatch.waitForExistence(timeout: 20))
    selectControl("Co-travel")
    let companion = application.buttons.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Sample route companion,")
    ).firstMatch
    XCTAssertTrue(companion.waitForExistence(timeout: 10))
    companion.click()
    let trust = application.buttons["Mark as trusted"]
    XCTAssertTrue(trust.waitForExistence(timeout: 10))
    trust.click()
    application.typeKey(",", modifierFlags: .command)
    selectControl("Trusted")
    let digest = SHA256.hash(data: Data("wardrive-atlas:co-travel:v1|BLE|DA1020304050".utf8))
      .map { String(format: "%02x", $0) }.joined()
    XCTAssertTrue(
      application.staticTexts["Saved device \(digest.prefix(12))"].waitForExistence(timeout: 10))
    let saved =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: settingsDirectory.appendingPathComponent("trust-v1.json")))
      as? [String: Any]
    XCTAssertEqual(saved?["devices"] as? [[String: String]], [["digest": digest, "type": "BLE"]])
  }
  func testCSVImportFromNativePanel() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Synthetic UI Capture.csv")
    try
      "MAC,SSID,CurrentLatitude,CurrentLongitude,Type,RSSI,AccuracyMeters,AltitudeMeters\nDA1020304050,UI Example,42,-71,BLE,-40,5,20\nDA1020304051,Ray-Ban UI,42.001,-71.001,BLE,1e30,1e100,1e300"
      .write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    XCTAssertTrue(application.buttons["importCSV"].waitForExistence(timeout: 10))
    application.buttons["importCSV"].click()
    application.typeKey("g", modifierFlags: [.command, .shift])
    application.typeText(file.path)
    application.typeKey(.return, modifierFlags: [])
    let open = application.dialogs["open-panel"].buttons["OKButton"]
    XCTAssertTrue(open.waitForExistence(timeout: 10))
    open.click()
    XCTAssertTrue(application.staticTexts["2"].firstMatch.waitForExistence(timeout: 15))
    XCTAssertTrue(application.checkBoxes["Synthetic UI Capture.csv"].exists)
    let candidate = application.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "candidate-")
    ).firstMatch
    XCTAssertTrue(candidate.waitForExistence(timeout: 5))
    candidate.click()
    XCTAssertTrue(application.staticTexts["Why it was flagged"].waitForExistence(timeout: 5))
  }
  func testNativeStreetMapModesAndOfflineFallback() throws {
    application.buttons["loadSample"].click()
    XCTAssertTrue(application.staticTexts["240"].firstMatch.waitForExistence(timeout: 20))
    let streets = application.checkBoxes["streetMap"]
    XCTAssertTrue(streets.exists)
    streets.click()
    for label in ["Clusters", "Heatmap", "Points"] {
      let control = application.radioButtons[label]
      XCTAssertTrue(control.waitForExistence(timeout: 10))
      control.click()
    }
    let screenshot = XCTAttachment(screenshot: application.windows.firstMatch.screenshot())
    screenshot.lifetime = .keepAlways
    add(screenshot)
    streets.click()
    XCTAssertTrue(
      application.staticTexts["Offline grid · no street-map requests"].waitForExistence(timeout: 10)
    )
    application.buttons["clearCaptures"].click()
    XCTAssertTrue(application.buttons["loadSample"].waitForExistence(timeout: 10))
  }
  func testStreetMapFailureOffersOfflineGrid() throws {
    application.terminate()
    application.launchEnvironment["ATLAS_MAP_FAILURE"] = "1"
    application.launch()
    let streets = application.checkBoxes["streetMap"]
    XCTAssertTrue(streets.waitForExistence(timeout: 10))
    streets.click()
    XCTAssertTrue(
      application.staticTexts[
        "Street map unavailable · turn off Street map to use the offline grid"
      ].waitForExistence(timeout: 10))
    streets.click()
    XCTAssertTrue(
      application.staticTexts["Offline grid · no street-map requests"].waitForExistence(timeout: 10)
    )
    application.buttons["loadSample"].click()
    XCTAssertTrue(application.staticTexts["240"].firstMatch.waitForExistence(timeout: 20))
  }
  func testClearRejectsPendingAnalysisAndWindowReopens() throws {
    application.buttons["loadSample"].click()
    application.buttons["clearCaptures"].click()
    XCTAssertTrue(application.buttons["loadSample"].waitForExistence(timeout: 10))
    let stale = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == true"),
      object: application.staticTexts["240"].firstMatch)
    stale.isInverted = true
    wait(for: [stale], timeout: 2)
    application.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()
    if application.wait(for: .notRunning, timeout: 2) {
      application.launch()
    } else {
      application.typeKey("1", modifierFlags: .command)
    }
    XCTAssertTrue(application.buttons["loadSample"].waitForExistence(timeout: 10))
  }
  func testLargeCaptureMapInteraction() throws {
    guard ProcessInfo.processInfo.environment["ATLAS_UI_BENCHMARK"] == "1" else {
      throw XCTSkip("Run with ATLAS_UI_BENCHMARK=1 for the 10k/100k map workloads.")
    }
    application.terminate()
    try FileManager.default.createDirectory(
      at: settingsDirectory, withIntermediateDirectories: true)
    let devices = (0..<10_000).map { ["digest": String(format: "%064x", $0), "type": "BLE"] }
    let data = try JSONSerialization.data(withJSONObject: ["version": 1, "devices": devices])
    try data.write(to: settingsDirectory.appendingPathComponent("trust-v1.json"))
    for count in [10_000, 100_000] {
      application.terminate()
      application.launchEnvironment["ATLAS_BENCHMARK_COUNT"] = String(count)
      application.launch()
      XCTAssertTrue(
        application.staticTexts[count.formatted()].firstMatch.waitForExistence(timeout: 90))
      let coTravelStart = Date()
      selectControl("Co-travel")
      XCTAssertTrue(application.staticTexts["Sensitivity"].waitForExistence(timeout: 10))
      print(
        "ATLAS_UI_BENCHMARK rows=\(count) savedTrust=10000 Co-travel: \(Date().timeIntervalSince(coTravelStart)) seconds"
      )
      for streetMap in [false, true] {
        if streetMap { application.checkBoxes["streetMap"].click() }
        let start = Date()
        for label in ["Clusters", "Heatmap", "Points"] {
          let control = application.radioButtons[label]
          XCTAssertTrue(control.waitForExistence(timeout: 10))
          control.click()
        }
        application.typeKey("0", modifierFlags: .command)
        print(
          "ATLAS_UI_BENCHMARK rows=\(count) streetMap=\(streetMap) mode switches and fit: \(Date().timeIntervalSince(start)) seconds"
        )
        let screenshot = XCTAttachment(screenshot: application.windows.firstMatch.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
      }
      let settingsStart = Date()
      application.typeKey(",", modifierFlags: .command)
      selectControl("Trusted")
      XCTAssertTrue(
        application.staticTexts["Saved device 000000000000"].firstMatch.waitForExistence(
          timeout: 10))
      print(
        "ATLAS_UI_BENCHMARK rows=\(count) savedTrust=10000 Trusted settings: \(Date().timeIntervalSince(settingsStart)) seconds"
      )
      capture("Populated Trusted settings at \(count) observations")
      application.windows.containing(.staticText, identifier: "Trusted devices").firstMatch
        .buttons[XCUIIdentifierCloseWindow].click()
      application.buttons["clearCaptures"].click()
      XCTAssertTrue(application.buttons["loadSample"].waitForExistence(timeout: 10))
    }
  }
}
