import Foundation

/// `~/Library/Application Support/Hearsay/recording.pid`: present with a live pid while any instance
/// records. `scripts/build-app.sh` refuses to install while it is held.
public struct RecordingLock: Sendable {
    public let url: URL

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Hearsay/recording.pid")
    }

    public init(url: URL = RecordingLock.defaultURL) { self.url = url }

    public func acquire(pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? AtomicFile.write("\(pid)\n", to: url)
    }

    /// Removes the file only if it still names `pid` (a second instance may have taken it).
    public func release(pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        if holder() == pid { try? FileManager.default.removeItem(at: url) }
    }

    public func holder() -> Int32? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// True when the file names a process that is still alive.
    public var isHeld: Bool {
        guard let pid = holder() else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
