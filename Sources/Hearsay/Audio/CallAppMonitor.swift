import CoreAudio
import Foundation
import HearsayCore

/// Watches Core Audio's per-process `IsRunningInput`. When a new (not ignored) app starts mic input,
/// the tap is stopped, we wait until that app has an input device (input scope of
/// `kAudioProcessPropertyDevices`, at most 30 s; a blocked Zoom reads as running input with no input
/// devices), then the tap is rebuilt 0.5 s later. Polls once a second on the main queue: simpler than
/// re-registering a listener on every process object, and a second is well inside Zoom's 14 s timeout.
final class CallAppMonitor {
    private let log = HSLog("callapp")
    private let tap: SystemTapCapture
    private var timer: Timer?
    private var previous: Set<pid_t> = []
    /// Bundle ids of the apps that have used the mic during this recording (for end detection).
    private(set) var micApps: Set<String> = []
    /// Some app other than us (and dictation) is running mic input now: a call app holding audio.
    /// End detection's "call ended" rule watches this go false.
    private(set) var callAppAudio = false

    init(tap: SystemTapCapture) { self.tap = tap }

    func start() {
        previous = Set(Self.inputProcesses().map(\.pid))  // apps already in a call keep working with a later tap
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let current = Self.inputProcesses()
        let fresh = CallAppPolicy.newInputUsers(previous: previous, current: current.map { ($0.pid, $0.bundleID) },
                                                ownPID: getpid())
        previous = Set(current.map(\.pid))
        callAppAudio = current.contains { !CallAppPolicy.isIgnored(bundleID: $0.bundleID, pid: $0.pid, ownPID: getpid()) }
        for p in current where !CallAppPolicy.isIgnored(bundleID: p.bundleID, pid: p.pid, ownPID: getpid()) {
            if let b = p.bundleID { micApps.insert(b) }
        }
        guard let pid = fresh.first, let proc = current.first(where: { $0.pid == pid }) else { return }
        let name = proc.bundleID ?? "pid \(pid)"
        let token = tap.pause(reason: "\(name) started mic input")
        waitForInputDevice(proc.object, name: name, token: token, deadline: Date().addingTimeInterval(CallAppPolicy.inputDeviceWait))
    }

    private func waitForInputDevice(_ object: AudioObjectID, name: String, token: RestartGeneration.Token, deadline: Date) {
        guard tap.isCurrent(token) else { return }
        let devices = (try? CA.array(object, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput,
                                     of: AudioObjectID.self)) ?? []
        if !devices.isEmpty || Date() >= deadline {
            log.info(devices.isEmpty ? "\(name) has no input device after 30 s; rebuilding tap anyway"
                                     : "\(name) has its input device; rebuilding tap in 0.5 s")
            tap.resume(token, after: CallAppPolicy.rebuildDelay)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.waitForInputDevice(object, name: name, token: token, deadline: deadline)
        }
    }

    struct Proc { let object: AudioObjectID; let pid: pid_t; let bundleID: String? }

    static func inputProcesses() -> [Proc] {
        let objects = (try? CA.array(CA.system, kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)) ?? []
        return objects.compactMap { obj in
            guard let running = try? CA.get(obj, kAudioProcessPropertyIsRunningInput, initial: UInt32(0)), running != 0,
                  let pid = try? CA.get(obj, kAudioProcessPropertyPID, initial: pid_t(0)) else { return nil }
            return Proc(object: obj, pid: pid, bundleID: CA.string(obj, kAudioProcessPropertyBundleID))
        }
    }
}
