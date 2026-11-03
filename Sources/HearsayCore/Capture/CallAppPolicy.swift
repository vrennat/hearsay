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
    /// A known app that restarts input pauses the tap only if it is still running input with no input
    /// device after this long (the blocked-Zoom signature).
    public static let blockedGrace: TimeInterval = 5
    /// A start of input counts as a restart only within this long of the same pid or bundle id stopping.
    public static let restartWindow: TimeInterval = 10

    public static func isIgnored(bundleID: String?, pid: Int32, ownPID: Int32,
                                 ignored: Set<String> = ignoredBundleIDs) -> Bool {
        if pid == ownPID { return true }
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return false }
        return ignored.contains { $0.lowercased() == id }
    }
}

/// Decides, poll by poll, which processes starting mic input pause the tap. An app that restarts input
/// (same pid or same bundle id stopped input within `restartWindow`) does not pause it again: Zoom
/// restarts its mic input mid-call (a screen share with sound did it), and rebuilding the tap then, while
/// AirPods were still reconfiguring, left the Mac's output silent for the rest of the call (2026-11-02).
/// A start after a longer gap (Zoom relaunched, a second call) pauses as before. A restart still pauses
/// the tap if it looks blocked: running input with no input device for `blockedGrace`.
public struct CallAppTracker: Sendable {
    public struct Proc: Sendable {
        public let pid: Int32
        public let bundleID: String?
        public let hasInputDevice: Bool
        public init(pid: Int32, bundleID: String?, hasInputDevice: Bool) {
            self.pid = pid; self.bundleID = bundleID; self.hasInputDevice = hasInputDevice
        }
    }

    private let ownPID: Int32
    private var previous: Set<Int32> = []
    /// Non-ignored input users at the last poll, with their lowercased bundle ids.
    private var previousLive: [Int32: String?] = [:]
    private var pidStopped: [Int32: Double] = [:]
    private var bundleStopped: [String: Double] = [:]
    /// Lowercased bundle ids of the apps that have used the mic during this recording.
    public private(set) var knownBundleIDs: Set<String> = []
    /// Known apps that restarted input and have no input device yet, with when the restart was seen.
    private var restartedAt: [Int32: Double] = [:]

    /// `alreadyRunning`: input users when recording starts; apps already in a call keep working with a later tap.
    public init(ownPID: Int32, alreadyRunning: [Proc]) {
        self.ownPID = ownPID
        previous = Set(alreadyRunning.map(\.pid))
        remember(alreadyRunning)
    }

    private func isLive(_ p: Proc) -> Bool { !CallAppPolicy.isIgnored(bundleID: p.bundleID, pid: p.pid, ownPID: ownPID) }

    /// Pids to pause the tap for, from the processes running input now (`now` in seconds, any clock).
    public mutating func poll(_ current: [Proc], now: Double) -> [Int32] {
        let live = current.filter(isLive)
        let livePIDs = Set(live.map(\.pid))
        for (pid, bundle) in previousLive where !livePIDs.contains(pid) {
            pidStopped[pid] = now
            if let bundle { bundleStopped[bundle] = now }
        }
        var pause: [Int32] = []
        for p in live where !previous.contains(p.pid) {
            if isRestart(p, now: now) { restartedAt[p.pid] = now } else { pause.append(p.pid) }
        }
        for p in live {
            guard let since = restartedAt[p.pid] else { continue }
            if p.hasInputDevice {
                restartedAt[p.pid] = nil
            } else if now - since >= CallAppPolicy.blockedGrace {
                restartedAt[p.pid] = nil
                pause.append(p.pid)
            }
        }
        restartedAt = restartedAt.filter { livePIDs.contains($0.key) }
        remember(live)
        previous = Set(current.map(\.pid))
        return pause
    }

    private func isRestart(_ p: Proc, now: Double) -> Bool {
        func recent(_ t: Double?) -> Bool { t.map { now - $0 <= CallAppPolicy.restartWindow } ?? false }
        return recent(pidStopped[p.pid]) || recent(Self.key(p.bundleID).flatMap { bundleStopped[$0] })
    }

    private static func key(_ bundleID: String?) -> String? {
        guard let b = bundleID?.lowercased(), !b.isEmpty else { return nil }
        return b
    }

    private mutating func remember(_ procs: [Proc]) {
        previousLive = [:]
        for p in procs where isLive(p) {
            previousLive[p.pid] = Self.key(p.bundleID)
            if let b = Self.key(p.bundleID) { knownBundleIDs.insert(b) }
        }
    }
}

/// When a tap rebuild may go ahead. A Bluetooth headset switching profile (AirPods into call mode)
/// changes its streams and rate several times within a second or two, and an aggregate built on it
/// mid-change left the output silent (2026-11-02). So a rebuild waits until the output device has had
/// no change for `quiet` seconds, but never more than `maxWait` in all, so a device that keeps
/// changing cannot stall the tap.
public enum OutputSettle {
    public static let quiet: TimeInterval = 2
    public static let maxWait: TimeInterval = 15

    /// Seconds still to wait (0: build now). All times in seconds on one monotonic clock.
    public static func wait(now: Double, lastChange: Double?, waitingSince: Double) -> Double {
        guard let lastChange else { return 0 }
        return max(0, min(lastChange + quiet - now, waitingSince + maxWait - now))
    }
}
