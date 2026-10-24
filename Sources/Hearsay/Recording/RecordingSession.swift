import AVFoundation
import Foundation
import HearsayCore
import Observation

/// One recording: mic + system tap writing CAFs into the meeting folder, call-app pause, mic-silence
/// watchdog and sleep guard. Published state (elapsed, levels, warnings) is refreshed at 10 Hz from a
/// lock-protected box the audio threads write, so buffers never hop to the main thread one by one.
@MainActor @Observable
final class RecordingSession {
    enum Warning: Hashable {
        case micSilent
        case micFailed(String)
        case tapFailed(String)

        var text: String {
            switch self {
            case .micSilent: return "No mic audio for 10 s"
            case .micFailed(let e): return "Mic: \(e)"
            case .tapFailed(let e): return "Call audio: \(e)"
            }
        }
    }

    static let micSilenceLimit: Double = 10

    private let log = HSLog("session")
    let store: MeetingStore
    private(set) var meeting: Meeting
    var meetingID: String { meeting.id }
    let startedAt: Date
    private let startHost: UInt64
    var startHostTime: UInt64 { startHost }

    private(set) var elapsed: TimeInterval = 0
    /// dBFS, floor when no buffer for 0.3 s.
    private(set) var micLevel: Float = AudioLevel.floor
    private(set) var systemLevel: Float = AudioLevel.floor
    /// Level, last buffer and last loud (> -46 dBFS) buffer per stream, host seconds; end detection reads these.
    private(set) var micActivity = AudioLevel()
    private(set) var systemActivity = AudioLevel()
    private(set) var warnings: Set<Warning> = []

    var micActive: Bool { micLevel > AudioLevel.floor }
    var callActive: Bool { systemLevel > AudioLevel.floor }

    private let mic: MicCapture
    private let tap: SystemTapCapture
    private let callApps: CallAppMonitor
    private let sleepGuard: SleepGuard
    private let lock = RecordingLock()
    private var ticker: Timer?
    private var lastMicRetry: Double = 0
    private(set) var isStopped = false

    private init(store: MeetingStore, meeting: Meeting, startHost: UInt64, sleepGuard: SleepGuard) {
        self.store = store
        self.meeting = meeting
        self.startedAt = meeting.startedAt
        self.startHost = startHost
        self.sleepGuard = sleepGuard
        let audio = store.folder(meeting.id).appendingPathComponent("audio", isDirectory: true)
        mic = MicCapture(url: audio.appendingPathComponent("mic.caf"), meetingStartHostTime: startHost)
        tap = SystemTapCapture(url: audio.appendingPathComponent("system.caf"), meetingStartHostTime: startHost)
        callApps = CallAppMonitor(tap: tap)
    }

    /// Creates the meeting (`meeting.json` written once, status `recording`) and starts both streams.
    /// A stream that fails to start is a warning, not a failed recording: the other one still records.
    static func start(store: MeetingStore, title: String?, sleepGuard: SleepGuard) async throws -> RecordingSession {
        let log = HSLog("session")
        await requestMicAccess(log: log)
        let startHost = HostClock.now()
        let meeting = try RecordingLifecycle.begin(store: store, startedAt: Date(), title: title)
        let s = RecordingSession(store: store, meeting: meeting, startHost: startHost, sleepGuard: sleepGuard)
        log.info("Recording \(meeting.id) in \(store.root.path)")
        s.lock.acquire()
        s.sleepGuard.engage(reason: "Hearsay is recording a meeting")
        s.begin()
        return s
    }

    private func begin() {
        let box = LevelBox.shared
        box.reset()
        mic.onBuffer = { db, t in box.record(.mic, db, t) }
        tap.onBuffer = { db, t in box.record(.system, db, t) }
        let feed = LiveFeed.shared
        feed.begin(meetingID: meeting.id, store: store, startHost: startHost) { LiveModel.shared.update($0) }
        mic.onPCM = { b, h in feed.push(.mic, b, hostTime: h) }
        tap.onPCM = { b, h in feed.push(.system, b, hostTime: h) }
        do { try mic.start() } catch {
            log.error("Mic did not start: \(error)")
            warnings.insert(.micFailed(String(describing: error)))
        }
        do { try tap.start() } catch {
            log.error("Tap did not start: \(error)")
            warnings.insert(.tapFailed(String(describing: error)))
        }
        callApps.start()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        guard !isStopped else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        let now = HostClock.seconds(HostClock.now())
        let (m, s) = LevelBox.shared.snapshot()
        micActivity = m
        systemActivity = s
        micLevel = m.displayLevel(now: now)
        systemLevel = s.displayLevel(now: now)
        RecordingUI.shared.tick(self, nowHost: now, mic: m, system: s, callAppAudio: callApps.callAppAudio)

        // Mic watchdog: no buffer for 10 s -> warn, notify once, retry every 10 s; clear on return.
        let sinceMic = now - (m.lastBufferAt ?? HostClock.seconds(startHost))
        if sinceMic >= Self.micSilenceLimit {
            if !warnings.contains(.micSilent) {
                warnings.insert(.micSilent)
                log.error("No mic buffer for \(Int(sinceMic)) s")
                Notifier.post(id: "mic-silent", title: "Hearsay is not hearing the mic",
                              body: "No microphone audio for 10 seconds. Still trying.")
            }
            if now - lastMicRetry >= Self.micSilenceLimit {
                lastMicRetry = now
                mic.restart(reason: "no mic buffer for \(Int(sinceMic)) s")
            }
        } else if warnings.contains(.micSilent) {
            warnings.remove(.micSilent)
            warnings = warnings.filter { if case .micFailed = $0 { return false } else { return true } }
            log.info("Mic buffers are back")
            Notifier.remove(id: "mic-silent")
        }
    }

    /// Calendar attendees and `me`, written into `meeting.json` right after `begin` so a crash keeps them.
    func adoptCalendar(attendees: [String], me: String?) {
        meeting.attendees = attendees
        meeting.me = me
        do { try store.saveMeeting(meeting) } catch { log.error("Could not save calendar attendees: \(error)") }
    }

    /// Stops both streams and writes `meeting.json` the second and last time (`recorded`).
    func stop(reason: String) -> Meeting {
        guard !isStopped else { return meeting }
        isStopped = true
        ticker?.invalidate()
        callApps.stop()
        let streams = [mic.stop(), tap.stop()].compactMap { $0 }
        sleepGuard.release()
        lock.release()
        log.info("Stopped \(meeting.id) (\(reason)); streams: "
                 + streams.map { "\($0.kind.rawValue) offset \(String(format: "%.3f", $0.startOffset)) s @ \($0.sampleRate ?? 0) Hz x \($0.channels ?? 0)" }.joined(separator: ", "))
        do {
            meeting = try RecordingLifecycle.finish(meeting, store: store, endedAt: Date(), streams: streams,
                                                    error: streams.isEmpty ? "no audio captured" : nil)
        } catch {
            log.error("Could not write meeting.json at stop: \(error)")
        }
        return meeting
    }

    private static func requestMicAccess(log: HSLog) async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            log.info("Asking for microphone access")
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            if ok { log.info("Microphone access granted") } else {
                log.error("Microphone access denied at the prompt; recording call audio only")
            }
        case .denied, .restricted:
            log.error("Microphone access denied: enable Hearsay in System Settings > Privacy & Security > Microphone. Recording call audio only")
        @unknown default: return
        }
    }
}

/// Written from the audio threads, read by the session's 10 Hz tick.
final class LevelBox: @unchecked Sendable {
    static let shared = LevelBox()
    private let lock = NSLock()
    private var mic = AudioLevel()
    private var system = AudioLevel()

    func reset() { lock.lock(); mic = AudioLevel(); system = AudioLevel(); lock.unlock() }

    func record(_ kind: StreamKind, _ db: Float, _ t: Double) {
        lock.lock(); defer { lock.unlock() }
        if kind == .mic { mic.record(dBFS: db, at: t) } else { system.record(dBFS: db, at: t) }
    }

    func snapshot() -> (AudioLevel, AudioLevel) { lock.lock(); defer { lock.unlock() }; return (mic, system) }
}
