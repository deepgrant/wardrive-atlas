import XCTest

final class WardriveAtlasUITests: XCTestCase {
  private var application: XCUIApplication!
  override func setUpWithError() throws {
    continueAfterFailure = false
    application = XCUIApplication()
    application.launchEnvironment["ATLAS_OFFLINE"] = "1"
    application.launchEnvironment["ATLAS_SETTINGS_DIRECTORY"] =
      FileManager.default.temporaryDirectory.appendingPathComponent("atlas-ui-\(UUID().uuidString)")
      .path
    application.launch()
    _ = application.windows.firstMatch.waitForExistence(timeout: 10)
  }
  override func tearDownWithError() throws { application.terminate() }
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
    XCTAssertTrue(application.staticTexts["Identifier privacy"].waitForExistence(timeout: 8))
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
    for count in [10_000, 100_000] {
      application.terminate()
      application.launchEnvironment["ATLAS_BENCHMARK_COUNT"] = String(count)
      application.launch()
      XCTAssertTrue(
        application.staticTexts[count.formatted()].firstMatch.waitForExistence(timeout: 90))
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
      application.buttons["clearCaptures"].click()
      XCTAssertTrue(application.buttons["loadSample"].waitForExistence(timeout: 10))
    }
  }
}
