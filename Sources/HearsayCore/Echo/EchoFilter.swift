import Foundation

/// Removes the words one stream only heard as an echo of the other (spec, post-call step 3).
///
/// Two cases. Speaker echo: the mic hears the call through the speakers, so the mic's words go.
/// Room-on-call: the call carries the room back about 0.3 s after the mic heard it, so the
/// system stream's words go. The two 10 ms loudness curves (meeting time, `Loudness.meetingCurve`)
/// are compared in 1.5 s windows; a window counts only when a neighbour also matches at a lag
/// within 50 ms, because unrelated speech reaches the match level in 5 to 15% of windows at
/// scattered lags.
///
/// Everything here is pure and works on arbitrary window ranges, so the live transcriber can call
/// `match` for each new window once both streams have audio 1 s past it, then `decide` and `filter`.
public enum EchoFilter {
    public static let windowSeconds = 1.5
    public static let windowFrames = Loudness.frames(windowSeconds)  // 150
    /// Lags searched in both directions. Measured room-on-call lag: 0.2 to 0.35 s.
    public static let maxLagFrames = Loudness.frames(0.5)
    /// A copy at least this far behind the mic is the call's echo of the room.
    public static let callEchoMinLagFrames = Loudness.frames(0.1)
    /// Neighbouring windows must agree on the lag within this.
    public static let neighbourLagFrames = Loudness.frames(0.05)
    /// Pearson correlation of the two dB curves that counts as a match.
    public static let matchLevel: Float = 0.75
    /// Both slices need this many loud frames (0.3 s) to be compared at all.
    public static let minLoudFrames = 30
    /// Unmatched windows use the echo stream seen in this many previous windows.
    public static let memoryWindows = 3
    /// A twin word in the fallback: the largest lag plus word-timing jitter (an echo's first word
    /// was timed 0.56 s after the original on the 2026-10-23 fixture).
    public static let twinSeconds = 0.75
    /// dB floor for correlation so digital silence does not dominate.
    static let correlationFloor: Float = -70

    /// Best match of one window. `lagFrames > 0`: system is behind the mic; `< 0`: mic is behind system.
    public struct Match: Sendable, Equatable {
        public let window: Int
        public let lagFrames: Int
        public let score: Float
        /// The stream whose words are the echo.
        public var echo: StreamKind { lagFrames >= EchoFilter.callEchoMinLagFrames ? .system : .mic }
    }

    public enum Kind: Sendable, Equatable {
        /// The window and a neighbour matched at the same lag.
        case confirmed
        /// No confirmed match; the fallback drops only words duplicated in the other stream.
        case fallback
    }

    public struct Decision: Sendable, Equatable {
        public let window: Int
        public let kind: Kind
        public let echo: StreamKind
        /// Seconds the echo stream lags the other in this window (0 for fallback).
        public let lag: Double
    }

    public static func windowCount(mic: [Float], sys: [Float]) -> Int { min(mic.count, sys.count) / windowFrames }

    /// Best-correlated lag for window `w`, or nil below the match level.
    public static func match(mic: [Float], sys: [Float], window w: Int) -> Match? {
        let start = w * windowFrames
        var best: Match?
        for lag in -maxLagFrames...maxLagFrames {
            // The leading stream is read at the window; the lagging one `|lag|` frames later.
            let (lead, follow) = lag >= 0 ? (mic, sys) : (sys, mic)
            let fStart = start + abs(lag)
            guard start + windowFrames <= lead.count, fStart + windowFrames <= follow.count else { continue }
            guard let r = correlation(lead, start, follow, fStart, windowFrames), r >= matchLevel else { continue }
            if best == nil || r > best!.score { best = Match(window: w, lagFrames: lag, score: r) }
        }
        return best
    }

    public static func matches(mic: [Float], sys: [Float], windows: Range<Int>) -> [Match?] {
        windows.map { match(mic: mic, sys: sys, window: $0) }
    }

    /// Decisions for windows `0..<matches.count` (index = window). A window is confirmed when
    /// `w-1` or `w+1` also matched at a lag within 50 ms; for the live caller the last window
    /// can only be confirmed through `w-1` until the next one arrives.
    ///
    /// `lookAhead` (batch only): an unmatched window with no confirmed echo in the previous 3 windows
    /// also takes the echo stream from the next 3 before defaulting to the mic. Without it, the first
    /// seconds of a room-on-call track (before a full window of the echo exists) dropped the mic's words.
    public static func decide(_ matches: [Match?], lookAhead: Bool = false) -> [Decision] {
        var out: [Decision] = []
        var lastEcho: (window: Int, stream: StreamKind)?
        for (w, m) in matches.enumerated() {
            if let m, neighbourAgrees(matches, w, m) {
                out.append(Decision(window: w, kind: .confirmed, echo: m.echo,
                                    lag: Double(abs(m.lagFrames)) * Loudness.frameSeconds))
                lastEcho = (w, m.echo)
            } else {
                let back = lastEcho.flatMap { w - $0.window <= memoryWindows ? $0.stream : nil }
                let ahead = lookAhead ? nextConfirmed(matches, after: w) : nil
                let stream = back ?? ahead ?? .mic
                out.append(Decision(window: w, kind: .fallback, echo: stream, lag: 0))
            }
        }
        return out
    }

    static func nextConfirmed(_ matches: [Match?], after w: Int) -> StreamKind? {
        for n in (w + 1)..<min(matches.count, w + 1 + memoryWindows) {
            if let m = matches[n], neighbourAgrees(matches, n, m) { return m.echo }
        }
        return nil
    }

    static func neighbourAgrees(_ matches: [Match?], _ w: Int, _ m: Match) -> Bool {
        for n in [w - 1, w + 1] where n >= 0 && n < matches.count {
            if let o = matches[n], abs(o.lagFrames - m.lagFrames) <= neighbourLagFrames { return true }
        }
        return false
    }

    public struct Result: Sendable {
        public var mic: [Word]
        public var sys: [Word]
        public var droppedMic: Int
        public var droppedSys: Int
        public var confirmedWindows: Int
    }

    /// Drops echo words. Confirmed window: every word of the echo stream whose midpoint falls in the
    /// window or the `lag` after it. Fallback window: only echo-stream words whose text the other
    /// stream also has within `twinSeconds`.
    public static func filter(mic: [Word], sys: [Word], decisions: [Decision]) -> Result {
        let byWindow = Dictionary(uniqueKeysWithValues: decisions.map { ($0.window, $0) })
        func keep(_ word: Word, stream: StreamKind, other: [Word]) -> Bool {
            let mid = (word.start + word.end) / 2
            // Try the window the word sits in, and the one before for a lagging copy.
            for w in Set([Int(mid / windowSeconds), Int(max(0, mid - 0.5) / windowSeconds)]) {
                guard let d = byWindow[w], d.echo == stream else { continue }
                // A confirmed window's copy runs `lag` past the window's end.
                let lo = Double(w) * windowSeconds, hi = lo + windowSeconds + d.lag
                guard mid >= lo, mid < hi else { continue }
                switch d.kind {
                case .confirmed: return false
                case .fallback: if hasTwin(word, in: other) { return false }
                }
            }
            return true
        }
        let m = mic.filter { keep($0, stream: .mic, other: sys) }
        let s = sys.filter { keep($0, stream: .system, other: mic) }
        return Result(mic: m, sys: s, droppedMic: mic.count - m.count, droppedSys: sys.count - s.count,
                      confirmedWindows: decisions.filter { $0.kind == .confirmed }.count)
    }

    /// Whole-meeting convenience: match every window, decide (with look-ahead), filter.
    public static func run(micCurve: [Float], sysCurve: [Float], mic: [Word], sys: [Word]) -> Result {
        let d = decide(matches(mic: micCurve, sys: sysCurve, windows: 0..<windowCount(mic: micCurve, sys: sysCurve)), lookAhead: true)
        return filter(mic: mic, sys: sys, decisions: d)
    }

    static func hasTwin(_ word: Word, in other: [Word]) -> Bool {
        let key = normalized(word.text)
        guard !key.isEmpty else { return false }
        return other.contains { abs($0.start - word.start) <= twinSeconds && normalized($0.text) == key }
    }

    static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func correlation(_ a: [Float], _ ai: Int, _ b: [Float], _ bi: Int, _ n: Int) -> Float? {
        var loudA = 0, loudB = 0
        var sa: Float = 0, sb: Float = 0
        for k in 0..<n {
            let x = max(a[ai + k], correlationFloor), y = max(b[bi + k], correlationFloor)
            if x > Loudness.loudDBFS { loudA += 1 }
            if y > Loudness.loudDBFS { loudB += 1 }
            sa += x; sb += y
        }
        guard loudA >= minLoudFrames, loudB >= minLoudFrames else { return nil }
        let ma = sa / Float(n), mb = sb / Float(n)
        var cov: Float = 0, va: Float = 0, vb: Float = 0
        for k in 0..<n {
            let x = max(a[ai + k], correlationFloor) - ma, y = max(b[bi + k], correlationFloor) - mb
            cov += x * y; va += x * x; vb += y * y
        }
        guard va > 0, vb > 0 else { return nil }
        return cov / (va * vb).squareRoot()
    }
}
