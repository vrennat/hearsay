import Foundation

/// Decides when a live echo window may be judged. The post-call echo filter works on 1.5 s windows;
/// the live transcript applies it "per window once both streams have audio 1 s past the window".
/// Pure, so the gating time is testable without audio.
public struct LiveEchoGate: Sendable, Equatable {
    public static let windowSeconds = 1.5
    public static let lookaheadSeconds = 1.0

    /// Index of the next window not yet judged.
    public private(set) var nextWindow = 0

    public init() {}

    public static func windowRange(_ k: Int) -> (start: Double, end: Double) {
        (Double(k) * windowSeconds, Double(k + 1) * windowSeconds)
    }

    public static func window(containing t: Double) -> Int { max(0, Int((t / windowSeconds).rounded(.down))) }

    /// Returns the windows that became ready, given how far (meeting time) each stream has audio.
    /// Nothing is ready until both streams have produced audio.
    public mutating func readyWindows(micAudioEnd: Double?, systemAudioEnd: Double?) -> [Int] {
        guard let m = micAudioEnd, let s = systemAudioEnd else { return [] }
        let reach = min(m, s)
        var ready: [Int] = []
        while Self.windowRange(nextWindow).end + Self.lookaheadSeconds <= reach + 1e-9 {
            ready.append(nextWindow)
            nextWindow += 1
        }
        return ready
    }
}

/// Per-window echo match. Inputs are each stream's 10 ms dBFS curve from the window start to 1 s
/// past its end (room for the 0.5 s lag search); the window is index 0 of those slices.
public typealias LiveEchoMatcher = @Sendable (_ mic: [Float], _ system: [Float]) -> EchoFilter.Match?

/// Live echo state: the gate, one match per judged window, and the decisions over all of them.
/// Pure (curves come through a closure), so it is tested without the streaming models.
public struct LiveEchoTracker: Sendable {
    public private(set) var gate = LiveEchoGate()
    public private(set) var matches: [EchoFilter.Match?] = []
    public private(set) var decisions: [EchoFilter.Decision] = []

    public init() {}

    /// Matches each newly ready window, then re-decides every window: window k-1 can only be
    /// confirmed through neighbour k once k is matched. No look-ahead (batch only).
    /// `curve(stream, from, to)` returns that stream's meeting-time 10 ms dBFS curve.
    public mutating func advance(micAudioEnd: Double?, systemAudioEnd: Double?, matcher: LiveEchoMatcher = LiveEcho.match,
                                 curve: (StreamKind, Double, Double) -> [Float]) {
        let ready = gate.readyWindows(micAudioEnd: micAudioEnd, systemAudioEnd: systemAudioEnd)
        guard !ready.isEmpty else { return }
        for k in ready {
            let r = LiveEchoGate.windowRange(k)
            let to = r.end + LiveEchoGate.lookaheadSeconds
            let m = matcher(curve(.mic, r.start, to), curve(.system, r.start, to))
            matches.append(m.map { EchoFilter.Match(window: k, lagFrames: $0.lagFrames, score: $0.score) })
        }
        decisions = EchoFilter.decide(matches)
    }

    /// Words left after the decisions so far; undecided windows keep everything.
    public func filter(mic: [Word], sys: [Word]) -> (mic: [Word], sys: [Word]) {
        guard !decisions.isEmpty else { return (mic, sys) }
        let r = EchoFilter.filter(mic: mic, sys: sys, decisions: decisions)
        return (r.mic, r.sys)
    }
}

public enum LiveEcho {
    /// The pipeline's own window match; the live transcriber then runs `EchoFilter.decide` (no
    /// look-ahead) and `EchoFilter.filter`, so live and batch drop words by the same rules.
    public static let match: LiveEchoMatcher = { EchoFilter.match(mic: $0, sys: $1, window: 0) }
}
