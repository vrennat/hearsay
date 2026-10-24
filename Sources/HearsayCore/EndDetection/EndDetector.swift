import Foundation

/// "Meeting over?" logic (spec, End detection). Pure: the app feeds it events with meeting-time
/// seconds and posts the notification when it returns a prompt. It never stops a recording itself.
///
/// Rules, checked on every event:
/// 1. Call ended: the call apps had audio, then held none for 15 s. Room talk is ignored here.
/// 2. Calendar ended 2+ min ago, and both mic and system have been quiet for 60 s.
/// 3. Nothing loud from either stream for 5 min.
/// After a prompt, no prompt for 15 min. Room talk (loud mic) keeps rules 2 and 3 from firing.
public struct EndDetector: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        /// A mic buffer louder than about -46 dBFS at t.
        case micLoud(Double)
        /// A system buffer louder than about -46 dBFS at t.
        case systemLoud(Double)
        /// The apps that used the mic started (true) or stopped (false) holding audio at t.
        case callAppAudio(present: Bool, at: Double)
        /// The calendar event's end, in meeting-time seconds; nil clears it.
        case calendarEnd(Double?)
        /// Clock tick at t.
        case tick(Double)
    }

    public enum Reason: String, Sendable, Equatable { case callEnded, calendarEnded, silence }

    public struct Prompt: Sendable, Equatable {
        public let reason: Reason
        public let at: Double
    }

    public static let callSilenceSeconds = 15.0
    public static let calendarGraceSeconds = 120.0
    public static let quietSeconds = 60.0
    public static let silenceSeconds = 300.0
    public static let holdoffSeconds = 900.0

    private var start: Double
    private var lastMicLoud: Double?
    private var lastSystemLoud: Double?
    private var callHadAudio = false
    private var callSilentSince: Double?
    private var calendarEnd: Double?
    private var lastPrompt: Double?
    private var now: Double

    public init(start: Double = 0) { self.start = start; self.now = start }

    /// Feeds one event; returns a prompt when one should be shown now.
    public mutating func handle(_ event: Event) -> Prompt? {
        switch event {
        case .micLoud(let t): advance(t); lastMicLoud = max(lastMicLoud ?? t, t)
        case .systemLoud(let t): advance(t); lastSystemLoud = max(lastSystemLoud ?? t, t)
        case .callAppAudio(let present, let t):
            advance(t)
            if present { callHadAudio = true; callSilentSince = nil } else if callHadAudio, callSilentSince == nil { callSilentSince = t }
        case .calendarEnd(let e): calendarEnd = e
        case .tick(let t): advance(t)
        }
        return evaluate()
    }

    private mutating func advance(_ t: Double) { now = max(now, t) }

    private mutating func evaluate() -> Prompt? {
        if let p = lastPrompt, now - p < Self.holdoffSeconds { return nil }
        let reason: Reason
        if let since = callSilentSince, now - since >= Self.callSilenceSeconds {
            reason = .callEnded
        } else if let end = calendarEnd, now - end >= Self.calendarGraceSeconds,
                  now - (lastMicLoud ?? start) >= Self.quietSeconds,
                  now - (lastSystemLoud ?? start) >= Self.quietSeconds {
            reason = .calendarEnded
        } else if now - max(lastMicLoud ?? start, lastSystemLoud ?? start) >= Self.silenceSeconds {
            reason = .silence
        } else {
            return nil
        }
        lastPrompt = now
        return Prompt(reason: reason, at: now)
    }
}
