import Foundation

/// Turns one stream's live words plus live diarizer segments into `LiveLine`s. Pure.
public enum LiveLineBuilder {
    public struct Segment: Sendable, Equatable {
        public let slot: Int
        public let start: Double
        public let end: Double
        public init(slot: Int, start: Double, end: Double) { self.slot = slot; self.start = start; self.end = end }
    }

    public static let pauseSeconds = 0.8
    public static let maxLineSeconds = 30.0

    /// Live speaker id: stream plus 1-based diarizer slot, e.g. `mic-1`, `sys-2`.
    public static func speakerID(_ stream: StreamKind, slot: Int) -> String {
        "\(stream == .mic ? "mic" : "sys")-\(slot + 1)"
    }

    /// The slot whose segments overlap the word most; with no overlap, the nearest segment within 1 s;
    /// else slot 0.
    static func slot(for w: Word, in segments: [Segment]) -> Int {
        var best: (slot: Int, overlap: Double)?
        var nearest: (slot: Int, gap: Double)?
        for s in segments {
            let o = min(w.end, s.end) - max(w.start, s.start)
            if o > 0, o > (best?.overlap ?? 0) { best = (s.slot, o) }
            let gap = max(s.start - w.end, w.start - s.end, 0)
            if gap < (nearest?.gap ?? .infinity) { nearest = (s.slot, gap) }
        }
        if let best { return best.slot }
        if let nearest, nearest.gap <= 1 { return nearest.slot }
        return 0
    }

    /// Appends streaming tokens to `words`. A token without a word-boundary prefix (`▁` or a space)
    /// continues the previous word even when it arrived in a later batch; FluidAudio's
    /// `buildWordTimings` cannot do that because it sees one drained batch at a time, which split
    /// words like "G reat" in live-sim.
    public static func appendTokens(_ tokens: [(token: String, start: Double, end: Double)], to words: inout [Word]) {
        for t in tokens {
            guard !t.token.isEmpty, t.token != "<blank>", t.token != "<pad>" else { continue }
            let boundary = t.token.hasPrefix("\u{2581}") || t.token.hasPrefix(" ")
            if !boundary, var last = words.popLast() {
                last.text += t.token
                // Punctuation can be emitted a chunk late; letting it stretch the word would hide the
                // pause before the next turn (live-sim merged two system turns 5 s apart).
                if t.token.contains(where: { $0.isLetter || $0.isNumber }) { last.end = max(last.end, t.end) }
                words.append(last)
            } else {
                let text = boundary ? String(t.token.dropFirst()) : t.token
                words.append(Word(text: text, start: t.start, end: t.end))
            }
        }
    }

    public static func lines(stream: StreamKind, words: [Word], segments: [Segment]) -> [LiveLine] {
        var out: [LiveLine] = []
        var lastEnd = -Double.infinity
        for w in words.sorted(by: { $0.start < $1.start }) {
            let text = w.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let id = speakerID(stream, slot: slot(for: w, in: segments))
            if var line = out.last, line.speaker == id, w.start - lastEnd < pauseSeconds, w.end - line.start <= maxLineSeconds {
                line.text += " " + text
                line.end = max(line.end, w.end)
                out[out.count - 1] = line
            } else {
                out.append(LiveLine(speaker: id, stream: stream, start: w.start, end: w.end, text: text))
            }
            lastEnd = w.end
        }
        return out
    }
}
