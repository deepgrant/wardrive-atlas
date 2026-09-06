// Verify a staged or installed app with only the macOS system tools on its runtime PATH.
import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
precondition(arguments.count == 2, "Pass the WardriveAtlas.app path")
let bundle = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let executable = bundle.appendingPathComponent("Contents/MacOS/WardriveAtlas")
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
  "atlas-smoke-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: temporary) }
let application = Process()
application.executableURL = executable
application.arguments = ["--sample"]
var environment = ProcessInfo.processInfo.environment
environment["PATH"] = "/usr/bin:/bin"
environment["ATLAS_OFFLINE"] = "1"
environment["ATLAS_SETTINGS_DIRECTORY"] = temporary.path
application.environment = environment
application.standardOutput = FileHandle.nullDevice
try application.run()
defer {
  if application.isRunning {
    application.terminate()
    application.waitUntilExit()
  }
}
var foundWindow = false
for _ in 0..<60 {
  guard application.isRunning else {
    throw NSError(
      domain: "WardriveAtlasSmoke", code: 1,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Application exited during launch (\(application.terminationStatus))."
      ])
  }
  let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
  foundWindow = windows.contains { window in
    guard (window[kCGWindowOwnerPID as String] as? Int32) == application.processIdentifier,
      let bounds = window[kCGWindowBounds as String] as? [String: Double]
    else { return false }
    return (bounds["Width"] ?? 0) > 500 && (bounds["Height"] ?? 0) > 400
  }
  if foundWindow { break }
  Thread.sleep(forTimeInterval: 0.2)
}
guard foundWindow else {
  throw NSError(
    domain: "WardriveAtlasSmoke", code: 2,
    userInfo: [NSLocalizedDescriptionKey: "Application ran but did not create its native window."])
}
Thread.sleep(forTimeInterval: 2)
guard application.isRunning else {
  throw NSError(
    domain: "WardriveAtlasSmoke", code: 3,
    userInfo: [NSLocalizedDescriptionKey: "Application exited after presenting its window."])
}
print("PASS: native app window opened with PATH=/usr/bin:/bin and an offline synthetic capture.")
