import AppKit
import HearsayCore

/// Dock icon and full menu bar only while a Hearsay window (main or Settings) is on screen; otherwise the
/// app stays a menu bar extra (LSUIElement). The policy flips to `.regular` before a window is ordered
/// front, so the window does not appear under an inactive app and then jump.
@MainActor
enum AppWindows {
    private static var installed = false
    private static var windows: [NSWindow?] { [MainWindowController.shared.window, settingsWindow] }
    /// SwiftUI's Settings window, found when it becomes key (it is opened through `openSettings`).
    private static weak var settingsWindow: NSWindow?

    static func isSettingsWindow(_ w: NSWindow) -> Bool {
        w.identifier?.rawValue.contains("Settings") == true
    }
    /// Previews render without a Dock icon.
    private static let pinnedAccessory = CommandLine.arguments.contains { $0.hasPrefix("--preview-") }

    static func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            // After the close finishes, so the closing window no longer counts as visible.
            DispatchQueue.main.async { MainActor.assumeIsolated { update() } }
        }
        // Settings gets the Hearsay menu bar too (Tanner): without it an accessory app shows the
        // previous app's menus over its own Settings window.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let w = note.object as? NSWindow, isSettingsWindow(w) else { return }
                settingsWindow = w
                guard !pinnedAccessory, NSApp.activationPolicy() != .regular else { return }
                HSLog("windows").info("Settings window \(w.identifier?.rawValue ?? "?"): regular activation")
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
            }
        }
    }

    static func willShow() {
        install()
        guard !pinnedAccessory, NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
    }

    static func update() {
        // A minimised window still owns its Dock tile.
        let open = windows.contains { $0.map { $0.isVisible || $0.isMiniaturized } ?? false }
        if !open, NSApp.activationPolicy() == .regular { NSApp.setActivationPolicy(.accessory) }
    }
}
