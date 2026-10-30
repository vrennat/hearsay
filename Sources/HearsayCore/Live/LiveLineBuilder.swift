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

    /// Unknown is deliberately distinct from the first detected voice. Stable ids keep old live files readable.
    public static func uncertainID(_ stream: StreamKind) -> String {
        stream == .system ? "sys-unknown" : "mic-unknown"
    }

    public static func isUncertain(_ id: String) -> Bool {
        id == "sys-unknown" || id == "mic-unknown"
    }

    /// Require temporal evidence. A nearby turn is not evidence that this word belongs to its speaker.
    /// Equal overlap from different voices is ambiguous (often overlapping speech).
    static func slot(for w: Word, in segments: [Segment]) -> Int? {
        var overlaps: [Int: Double] = [:]
        for s in segments where s.slot >= 0 {
            let overlap = min(w.end, s.end) - max(w.start, s.start)
            if overlap > 0 { overlaps[s.slot] = max(overlaps[s.slot] ?? 0, overlap) }
        }
        let ranked = overlaps.sorted { $0.value > $1.value }
        guard let best = ranked.first else { return nil }
        if ranked.count > 1, abs(best.value - ranked[1].value) < 0.000001 { return nil }
        return best.key
    }

    /// Content-free assignment counters. Segment slots and matched word slots distinguish model
    /// merging from absent/misaligned segments; no text, names, meeting ids or paths are included.
    public static func diagnostics(words: [Word], segments: [Segment]) -> String {
        let words = words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let assigned = words.compactMap { slot(for: $0, in: segments) }
        return "words=\(words.count) matched=\(assigned.count) uncertain=\(words.count - assigned.count) segmentSlots=\(Set(segments.map(\.slot)).count) matchedSlots=\(Set(assigned).count) segments=\(segments.count)"
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
            let id = slot(for: w, in: segments).map { speakerID(stream, slot: $0) } ?? uncertainID(stream)
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
