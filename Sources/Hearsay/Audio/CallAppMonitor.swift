import CoreAudio
import Foundation
import HearsayCore

/// Watches Core Audio's per-process `IsRunningInput`. When a new (not ignored) app starts mic input
/// (`CallAppTracker`: not one that already used input this recording, unless it looks blocked), the tap is stopped, we wait until that app has an input device (input scope of
/// `kAudioProcessPropertyDevices`, at most 30 s; a blocked Zoom reads as running input with no input
/// devices), then the tap is rebuilt 0.5 s later. Polls once a second on the main queue: simpler than
/// re-registering a listener on every process object, and a second is well inside Zoom's 14 s timeout.
final class CallAppMonitor {
    private let log = HSLog("callapp")
    private let tap: SystemTapCapture
    private var timer: Timer?
    private var tracker: CallAppTracker?
    /// Bundle ids (lowercased) of the apps that have used the mic during this recording.
    var micApps: Set<String> { tracker?.knownBundleIDs ?? [] }
    /// Some app other than us (and dictation) is running mic input now: a call app holding audio.
    /// End detection's "call ended" rule watches this go false.
    private(set) var callAppAudio = false

    init(tap: SystemTapCapture) { self.tap = tap }

    func start() {
        tracker = CallAppTracker(ownPID: getpid(), alreadyRunning: Self.inputProcesses().map(\.tracked))
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard var tracker else { return }
        let current = Self.inputProcesses()
        let known = tracker.knownBundleIDs
        let fresh = tracker.poll(current.map(\.tracked), now: ProcessInfo.processInfo.systemUptime)
        self.tracker = tracker
        callAppAudio = current.contains { !CallAppPolicy.isIgnored(bundleID: $0.bundleID, pid: $0.pid, ownPID: getpid()) }
        guard let pid = fresh.first, let proc = current.first(where: { $0.pid == pid }) else { return }
        let name = proc.bundleID ?? "pid \(pid)"
        let again = proc.bundleID.map { known.contains($0.lowercased()) } == true
        let token = tap.pause(reason: again ? "\(name) restarted mic input and has no input device after \(Int(CallAppPolicy.blockedGrace)) s"
                                            : "\(name) started mic input")
        waitForInputDevice(proc.object, name: name, token: token, deadline: Date().addingTimeInterval(CallAppPolicy.inputDeviceWait))
    }

    private func waitForInputDevice(_ object: AudioObjectID, name: String, token: RestartGeneration.Token, deadline: Date) {
        guard tap.isCurrent(token) else { return }
        let hasDevice = Self.hasInputDevice(object)
        if hasDevice || Date() >= deadline {
            log.info(hasDevice ? "\(name) has its input device; rebuilding tap once the output settles"
                               : "\(name) has no input device after 30 s; rebuilding tap anyway")
            tap.resume(token, after: CallAppPolicy.rebuildDelay)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.waitForInputDevice(object, name: name, token: token, deadline: deadline)
        }
    }

    struct Proc {
        let object: AudioObjectID; let pid: pid_t; let bundleID: String?
        var tracked: CallAppTracker.Proc {
            CallAppTracker.Proc(pid: pid, bundleID: bundleID, hasInputDevice: CallAppMonitor.hasInputDevice(object))
        }
    }

    static func hasInputDevice(_ object: AudioObjectID) -> Bool {
        !((try? CA.array(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput, of: AudioObjectID.self)) ?? []).isEmpty
    }

    static func inputProcesses() -> [Proc] {
        let objects = (try? CA.array(CA.system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)) ?? []
        return objects.compactMap { obj in
            guard let running = try? CA.get(obj, kAudioProcessPropertyIsRunningInput, initial: UInt32(0)), running != 0,
                  let pid = try? CA.get(obj, kAudioProcessPropertyPID, initial: pid_t(0)) else { return nil }
            return Proc(object: obj, pid: pid, bundleID: CA.string(obj, kAudioProcessPropertyBundleID))
        }
    }
}
