import Foundation

/// A diarizer turn in meeting time. `slot` is the diarizer's own speaker label on one stream.
public struct DiarSegment: Sendable, Equatable {
    public let slot: String
    public let start: Double
    public let end: Double
    public init(slot: String, start: Double, end: Double) { self.slot = slot; self.start = start; self.end = end }
}

/// Word-to-speaker attribution by overlap, and utterance building (spec step 2).
public enum Attribution {
    /// The slot whose segments overlap the word most; with no overlap, the nearest segment's slot
    /// (the diarizer trims word edges); with no segments at all, `"0"`.
    public static func slot(for word: Word, in segments: [DiarSegment]) -> String {
        guard !segments.isEmpty else { return "0" }
        var overlap: [String: Double] = [:]
        for s in segments {
            let o = min(word.end, s.end) - max(word.start, s.start)
            if o > 0 { overlap[s.slot, default: 0] += o }
        }
        if let best = overlap.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) {
            return best.key
        }
        let mid = (word.start + word.end) / 2
        return segments.min { distance(mid, $0) < distance(mid, $1) }!.slot
    }

    static func distance(_ t: Double, _ s: DiarSegment) -> Double { t < s.start ? s.start - t : max(0, t - s.end) }

    /// Speaker ids for one stream: slots ranked by talk time (attributed word time), `mic-1` first.
    /// Returns utterances (already split into runs of one speaker, then by `Segmenter`) and speakers
    /// with talk seconds taken from the utterances.
    public static func build(words: [Word], segments: [DiarSegment], stream: StreamKind) -> (speakers: [Speaker], utterances: [Utterance]) {
        let slots = words.map { slot(for: $0, in: segments) }
        var wordTime: [String: Double] = [:]
        for (w, s) in zip(words, slots) { wordTime[s, default: 0] += w.end - w.start }
        let ranked = wordTime.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.map(\.key)
        let prefix = stream == .mic ? "mic" : "sys"
        let idFor = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($0.element, "\(prefix)-\($0.offset + 1)") })

        var utterances: [Utterance] = []
        var run: [Word] = []
        var runSlot: String?
        func flush() {
            guard let s = runSlot, !run.isEmpty else { return }
            utterances += Segmenter.utterances(words: run, speaker: idFor[s]!, stream: stream)
            run = []
        }
        for (w, s) in zip(words, slots) {
            if s != runSlot { flush(); runSlot = s }
            run.append(w)
        }
        flush()

        let speakers = ranked.enumerated().map { i, slot -> Speaker in
            let id = idFor[slot]!
            let talk = utterances.filter { $0.speaker == id }.reduce(0) { $0 + ($1.end - $1.start) }
            return Speaker(id: id, stream: stream, defaultLabel: defaultLabel(stream: stream, number: i + 1), talkSeconds: talk)
        }
        return (speakers, utterances)
    }

    /// `Room N` on the mic, `Remote N` on the system stream. `Me` is set only by speaker naming.
    public static func defaultLabel(stream: StreamKind, number: Int) -> String {
        stream == .mic ? "Room \(number)" : "Remote \(number)"
    }

    /// Spans (start, end) of `speaker`'s utterances of 2 s or more that overlap no other speaker's
    /// utterance on the same stream, longest first, cut to `limit` seconds in total (spec step 6).
    public static func cleanSpans(for speaker: String, in utterances: [Utterance], minLength: Double = 2, limit: Double = 60) -> [(Double, Double)] {
        let mine = utterances.filter { $0.speaker == speaker && $0.end - $0.start >= minLength }
        let stream = mine.first?.stream
        let others = utterances.filter { $0.speaker != speaker && $0.stream == stream }
        let clean = mine.filter { u in !others.contains { $0.start < u.end && $0.end > u.start } }
            .sorted { $0.end - $0.start > $1.end - $1.start }
        var out: [(Double, Double)] = []
        var total = 0.0
        for u in clean where total < limit {
            let len = min(u.end - u.start, limit - total)
            out.append((u.start, u.start + len)); total += len
        }
        return out.sorted { $0.0 < $1.0 }
    }
}
