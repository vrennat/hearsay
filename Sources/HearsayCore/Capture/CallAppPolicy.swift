import Foundation

/// Which processes starting mic input pause the system tap. A running tap blocks a call app from
/// starting audio on the built-in mic (Zoom sat on "Connecting..."); a tap created after it is fine.
public enum CallAppPolicy {
    /// Compared lowercased. `com.apple.CoreSpeech` is dictation; without it every dictation restarts the tap.
    public static let ignoredBundleIDs: Set<String> = [
        "com.apple.corespeech",
        "com.tannervass.hearsay",
    ]

    public static let inputDeviceWait: TimeInterval = 30
    public static let rebuildDelay: TimeInterval = 0.5

    public static func isIgnored(bundleID: String?, pid: Int32, ownPID: Int32,
                                 ignored: Set<String> = ignoredBundleIDs) -> Bool {
        if pid == ownPID { return true }
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return false }
        return ignored.contains { $0.lowercased() == id }
    }

    /// Pids now running input that were not before and are not ignored.
    public static func newInputUsers(previous: Set<Int32>, current: [(pid: Int32, bundleID: String?)],
                                     ownPID: Int32) -> [Int32] {
        current.filter { !previous.contains($0.pid) && !isIgnored(bundleID: $0.bundleID, pid: $0.pid, ownPID: ownPID) }
            .map(\.pid)
    }
}
