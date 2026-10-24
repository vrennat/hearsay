import AppKit

/// Dock icon and full menu bar only while a Hearsay window (main or live) is on screen; otherwise the
/// app stays a menu bar extra (LSUIElement). The policy flips to `.regular` before a window is ordered
/// front, so the window does not appear under an inactive app and then jump.
@MainActor
enum AppWindows {
    private static var installed = false
    private static var windows: [NSWindow?] { [MainWindowController.shared.window, LiveWindowController.shared.window] }
    /// Previews render without a Dock icon.
    private static let pinnedAccessory = CommandLine.arguments.contains { $0.hasPrefix("--preview-") }

    static func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            // After the close finishes, so the closing window no longer counts as visible.
            DispatchQueue.main.async { MainActor.assumeIsolated { update() } }
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
