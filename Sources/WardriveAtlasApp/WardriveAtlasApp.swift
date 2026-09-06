import SwiftUI
import WardriveAtlasCore

@main
struct WardriveAtlasApp: App {
  @StateObject private var coordinator = AppCoordinator()
  @NSApplicationDelegateAdaptor(AtlasApplicationDelegate.self) private var delegate
  var body: some Scene {
    Window("Wardrive Atlas", id: "atlas") {
      RootView().environmentObject(coordinator).frame(minWidth: 1040, minHeight: 700).task {
        await coordinator.start()
      }
    }
    .defaultSize(width: 1440, height: 900)
    .defaultLaunchBehavior(.presented)
    .commands {
      AtlasWindowCommands()
      CommandGroup(after: .newItem) {
        Button("Import CSV…") { coordinator.openFiles() }.keyboardShortcut("o")
        Button("Load Sample Drive") { coordinator.loadSample() }.keyboardShortcut(
          "d", modifiers: [.command, .shift])
      }
      CommandMenu("Survey") {
        Button("Fit Observations") { coordinator.fitRevision += 1 }.keyboardShortcut("0")
        Button("Clear Captures") { coordinator.clear() }.keyboardShortcut(
          .delete, modifiers: [.command, .shift])
      }
    }
    Settings { AtlasSettingsView().environmentObject(coordinator).frame(width: 660, height: 620) }
  }
}

/// Open the SwiftUI Window scene through its native Window-menu action after restoration.
final class AtlasApplicationDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    DispatchQueue.main.async { self.presentSurveyWindow() }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    presentSurveyWindow()
    return true
  }
  private func presentSurveyWindow() {
    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "atlas" }) {
      window.makeKeyAndOrderFront(nil)
      return
    }
    func findSceneAction(in menu: NSMenu) -> NSMenuItem? {
      for item in menu.items {
        if item.title == "Show Wardrive Atlas", item.submenu == nil, item.action != nil {
          return item
        }
        if let submenu = item.submenu, let found = findSceneAction(in: submenu) { return found }
      }
      return nil
    }
    if let menu = NSApp.mainMenu, let item = findSceneAction(in: menu), let action = item.action {
      NSApp.sendAction(action, to: item.target, from: item)
    }
  }
}

struct AtlasWindowCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  var body: some Commands {
    CommandGroup(before: .newItem) {
      Button("Show Wardrive Atlas") { openWindow(id: "atlas") }
        .keyboardShortcut("1", modifiers: .command)
    }
  }
}
