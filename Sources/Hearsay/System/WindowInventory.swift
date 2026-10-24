import AppKit
import HearsayCore

/// Logs every window's address, class and view count, so a future AppKit layout-loop crash can be
/// tied to its window. Called at recording start and when the menu opens.
@MainActor
enum WindowInventory {
    private static let log = HSLog("windows")

    static func log(_ when: String) {
        let lines = NSApp.windows.map { w in
            let address = String(format: "%p", unsafeBitCast(w, to: Int.self))
            return "\(address) \(type(of: w)) views=\(w.contentView.map(count) ?? 0) visible=\(w.isVisible)"
        }
        log.info("Windows at \(when) (\(lines.count)): " + lines.joined(separator: "; "))
    }

    private static func count(_ v: NSView) -> Int { 1 + v.subviews.reduce(0) { $0 + count($1) } }
}
