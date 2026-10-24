import AppKit
import HearsayCore
import SwiftUI

@main
struct HearsayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    /// Read once: a scene's style cannot change while the app runs (Settings offers a restart).
    private let style = MenuStyle.current

    var body: some Scene {
        // `SceneBuilder` takes no `if`, so both extras exist and `isInserted` shows only the chosen one.
        MenuBarExtra(isInserted: .constant(style == .menu)) {
            StandardMenuContent(model: model)
        } label: {
            MenuBarIcon(state: model.menuBarState)
        }
        .menuBarExtraStyle(.menu)

        MenuBarExtra(isInserted: .constant(style == .panel)) {
            MenuContent(model: model)
        } label: {
            MenuBarIcon(state: model.menuBarState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
        .commands { MainMenuCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // LSUIElement in the bundle; this covers `swift run`
        MainActor.assumeIsolated {
            AppModel.shared.didFinishLaunching()
            if LaunchKind.showsMainWindow(notification) { MainWindowController.shared.show() }
        }
    }

    /// Dock icon click, `open -a Hearsay` or a Finder double-click while running: show the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { _ = MainWindowController.shared.show() } }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.willTerminate() }
    }
}

/// Whether this launch should open the main window. A person opening the app (Finder, Dock, `open -a`)
/// sends an "open application" Apple event; a login item is flagged `keyAELaunchedAsLogInItem` in it,
/// and a launch by launchd or straight from a shell (`swift run`, previews, test instances) has no event.
enum LaunchKind {
    @MainActor static func showsMainWindow(_ note: Notification) -> Bool {
        let log = HSLog("app")
        let event = NSAppleEventManager.shared().currentAppleEvent
        let isOpen = event?.eventClass == AEEventClass(kCoreEventClass) && event?.eventID == AEEventID(kAEOpenApplication)
        let loginItem = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
        let preview = CommandLine.arguments.contains { $0.hasPrefix("--preview-") }
        let show = isOpen && !loginItem && !preview && !AppModel.shared.options.isTestInstance
        log.info("Launch event \(event.map { "\($0.eventClass)/\($0.eventID)" } ?? "none"), login item \(loginItem): main window \(show ? "shown" : "not shown")")
        return show
    }
}
