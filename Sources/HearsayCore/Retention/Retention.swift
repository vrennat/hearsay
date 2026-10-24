import Foundation

/// Storage retention (spec, Retention). Decided by `startedAt` age; 0 days means forever and
/// `RetentionPlan.untilTranscribed` (-1, the audio default) removes audio as soon as a transcript exists.
public enum RetentionAction: String, Sendable, Equatable {
    /// Past the transcript limit: move the whole folder to the Trash.
    case trash
    /// Past the audio limit with `transcript.json` present: delete `audio/` for good.
    case removeAudio
}

public struct RetentionItem: Sendable, Equatable {
    public let id: String
    public let action: RetentionAction
    public let ageDays: Double
}

/// Meetings left alone and why; shown by `hearsay retention` so a missing action is explainable.
public struct RetentionSkip: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable { case busy, noTranscript, audioAlreadyRemoved }
    public let id: String
    public let reason: Reason
}

public struct RetentionPlan: Sendable, Equatable {
    /// `keepAudioDays` value: delete audio once the meeting is transcribed, whatever its age.
    public static let untilTranscribed = -1

    public var items: [RetentionItem] = []
    public var skipped: [RetentionSkip] = []

    public struct Input: Sendable {
        public let meeting: Meeting
        public let hasTranscript: Bool
        public init(meeting: Meeting, hasTranscript: Bool) { self.meeting = meeting; self.hasTranscript = hasTranscript }
    }

    /// Pure decision. `queued` holds ids the app has queued for processing (not a stored status).
    public static func make(
        _ inputs: [Input], now: Date, keepAudioDays: Int, keepTranscriptDays: Int, queued: Set<String> = []
    ) -> RetentionPlan {
        var plan = RetentionPlan()
        for input in inputs {
            let m = input.meeting
            let age = now.timeIntervalSince(m.startedAt) / 86_400
            let pastTranscript = keepTranscriptDays > 0 && age > Double(keepTranscriptDays)
            let pastAudio = keepAudioDays == Self.untilTranscribed || (keepAudioDays > 0 && age > Double(keepAudioDays))
            guard pastTranscript || pastAudio else { continue }
            if m.status == .recording || m.status == .processing || queued.contains(m.id) {
                plan.skipped.append(RetentionSkip(id: m.id, reason: .busy)); continue
            }
            if pastTranscript {
                plan.items.append(RetentionItem(id: m.id, action: .trash, ageDays: age))
            } else if m.audioRemovedAt != nil {
                plan.skipped.append(RetentionSkip(id: m.id, reason: .audioAlreadyRemoved))
            } else if !input.hasTranscript {
                plan.skipped.append(RetentionSkip(id: m.id, reason: .noTranscript))
            } else {
                plan.items.append(RetentionItem(id: m.id, action: .removeAudio, ageDays: age))
            }
        }
        return plan
    }

    public static func make(
        store: MeetingStore, now: Date = Date(), keepAudioDays: Int, keepTranscriptDays: Int, queued: Set<String> = []
    ) -> RetentionPlan {
        let inputs = store.loadAllMeetings().map { m in
            Input(meeting: m, hasTranscript: store.hasFile(m.id, MeetingStore.transcriptFile))
        }
        return make(inputs, now: now, keepAudioDays: keepAudioDays, keepTranscriptDays: keepTranscriptDays, queued: queued)
    }
}

public enum Retention {
    private static let log = HearsayCore.logger("retention")

    /// Carries out a plan. Re-reads each meeting first and re-checks its status, so a meeting that
    /// started processing after the plan was made is left alone. Returns the ids acted on.
    @discardableResult
    public static func apply(_ plan: RetentionPlan, store: MeetingStore, now: Date = Date()) -> [String] {
        let fm = FileManager.default
        var done: [String] = []
        for item in plan.items {
            do {
                var m = try store.loadMeeting(item.id)
                guard m.status != .recording, m.status != .processing else { continue }
                let folder = store.folder(item.id)
                switch item.action {
                case .trash:
                    try fm.trashItem(at: folder, resultingItemURL: nil)
                case .removeAudio:
                    guard store.hasFile(item.id, MeetingStore.transcriptFile) else { continue }
                    let audio = folder.appendingPathComponent("audio", isDirectory: true)
                    if fm.fileExists(atPath: audio.path) { try fm.removeItem(at: audio) }
                    m.streams = []
                    m.audioRemovedAt = now
                    try store.saveMeeting(m)
                }
                log.info("Retention \(item.action.rawValue, privacy: .public) \(item.id, privacy: .public)")
                done.append(item.id)
            } catch {
                log.error("Retention failed for \(item.id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return done
    }
}

/// Runs retention at launch and every 24 h. The app supplies the settings and the queued ids at fire
/// time so a settings change applies on the next run without rescheduling.
public final class RetentionScheduler: @unchecked Sendable {
    public static let interval: TimeInterval = 24 * 3600

    public struct Settings: Sendable {
        public let keepAudioDays: Int
        public let keepTranscriptDays: Int
        public let queued: Set<String>
        public init(keepAudioDays: Int, keepTranscriptDays: Int, queued: Set<String> = []) {
            self.keepAudioDays = keepAudioDays; self.keepTranscriptDays = keepTranscriptDays; self.queued = queued
        }
    }

    private let store: MeetingStore
    private let settings: @Sendable () -> Settings
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.tannervass.hearsay.retention", qos: .utility)

    public init(store: MeetingStore, settings: @escaping @Sendable () -> Settings) {
        self.store = store; self.settings = settings
    }

    /// Runs once now, then every 24 h until `stop()`.
    public func start() {
        queue.sync {
            timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: Self.interval, leeway: .seconds(60))
            t.setEventHandler { [weak self] in self?.runOnce() }
            timer = t
            t.resume()
        }
    }

    public func stop() { queue.sync { timer?.cancel(); timer = nil } }

    @discardableResult
    public func runOnce(now: Date = Date()) -> [String] {
        let s = settings()
        guard s.keepAudioDays != 0 || s.keepTranscriptDays > 0 else { return [] }
        let plan = RetentionPlan.make(store: store, now: now, keepAudioDays: s.keepAudioDays,
                                      keepTranscriptDays: s.keepTranscriptDays, queued: s.queued)
        return Retention.apply(plan, store: store, now: now)
    }
}
