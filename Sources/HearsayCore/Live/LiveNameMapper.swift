import Foundation

/// Hands live speaker names to final speakers after processing (spec, Live transcript): each live name
/// goes to the final speaker on the same stream whose utterances cover more than half of that live
/// voice's time, best covered first, one name per speaker.
public enum LiveNameMapper {
    public struct Span: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public init(_ start: Double, _ end: Double) { self.start = start; self.end = end }
    }

    public struct LiveVoice: Sendable, Equatable {
        public var id: String
        public var stream: StreamKind
        public var name: String
        public var spans: [Span]
        public init(id: String, stream: StreamKind, name: String, spans: [Span]) {
            self.id = id; self.stream = stream; self.name = name; self.spans = spans
        }
    }

    public struct FinalVoice: Sendable, Equatable {
        public var id: String
        public var stream: StreamKind
        public var spans: [Span]
        public init(id: String, stream: StreamKind, spans: [Span]) {
            self.id = id; self.stream = stream; self.spans = spans
        }
    }

    public static let minimumCoverage = 0.5

    /// Final speaker id to live name.
    public static func map(live: [LiveVoice], final: [FinalVoice]) -> [String: String] {
        struct Candidate { let live: Int; let final: Int; let coverage: Double }
        var candidates: [Candidate] = []
        for (li, l) in live.enumerated() {
            let total = l.spans.reduce(0) { $0 + max(0, $1.end - $1.start) }
            guard total > 0, !l.name.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            for (fi, f) in final.enumerated() where f.stream == l.stream {
                let c = overlap(l.spans, f.spans) / total
                if c > minimumCoverage { candidates.append(Candidate(live: li, final: fi, coverage: c)) }
            }
        }
        // Best covered first; ties keep input order so the result is deterministic.
        candidates.sort { $0.coverage != $1.coverage ? $0.coverage > $1.coverage : ($0.live, $0.final) < ($1.live, $1.final) }
        var usedLive = Set<Int>(), usedFinal = Set<Int>()
        var out: [String: String] = [:]
        for c in candidates where !usedLive.contains(c.live) && !usedFinal.contains(c.final) {
            usedLive.insert(c.live); usedFinal.insert(c.final)
            out[final[c.final].id] = live[c.live].name
        }
        return out
    }

    /// Convenience over the on-disk models: live speakers with names in `live.speakerNames`.
    public static func map(live: LiveTranscript, transcript: Transcript) -> [String: String] {
        var liveSpans: [String: (StreamKind, [Span])] = [:]
        for line in live.lines where live.speakerNames[line.speaker] != nil {
            liveSpans[line.speaker, default: (line.stream, [])].1.append(Span(line.start, line.end))
        }
        let liveVoices = liveSpans.keys.sorted().map { id in
            LiveVoice(id: id, stream: liveSpans[id]!.0, name: live.speakerNames[id]!, spans: liveSpans[id]!.1)
        }
        let finalVoices = transcript.speakers.map { s in
            FinalVoice(id: s.id, stream: s.stream,
                       spans: transcript.utterances.filter { $0.speaker == s.id }.map { Span($0.start, $0.end) })
        }
        return map(live: liveVoices, final: finalVoices)
    }

    /// Total overlap between two span lists. Each list is merged first so overlapping spans in one
    /// list do not count time twice.
    static func overlap(_ a: [Span], _ b: [Span]) -> Double {
        let ma = merged(a), mb = merged(b)
        var i = 0, j = 0, total = 0.0
        while i < ma.count && j < mb.count {
            let lo = max(ma[i].start, mb[j].start), hi = min(ma[i].end, mb[j].end)
            if hi > lo { total += hi - lo }
            if ma[i].end < mb[j].end { i += 1 } else { j += 1 }
        }
        return total
    }

    static func merged(_ spans: [Span]) -> [Span] {
        var out: [Span] = []
        for s in spans.filter({ $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
            if let last = out.last, s.start <= last.end { out[out.count - 1].end = max(last.end, s.end) } else { out.append(s) }
        }
        return out
    }
}
