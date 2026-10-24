import Accessibility
import AppKit
import HearsayCore

/// VoiceOver announcements for state changes the user cannot see while focus is elsewhere
/// (recording started or stopped, mic silent, meeting over). A no-op without an assistive client.
@MainActor
enum Announce {
    static func post(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
        HSLog("a11y").info("Announce: \(text)")
    }

    /// Reduce Motion, read from AppKit for code outside a SwiftUI environment (the pill's panel animation).
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
