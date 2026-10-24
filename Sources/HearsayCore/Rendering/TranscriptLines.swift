import Foundation

/// What the meeting window shows as the transcript: `transcript.json` with a matching `cleanup.json`,
/// else the live transcript (`live.json`, or `live.md` parsed when only the Markdown exists).
public struct TranscriptLines: Sendable, Equatable {
    public enum Source: String, Sendable { case transcript, cleanedTranscript, live, liveMarkdown, none }

    public struct Line: Sendable, Equatable, Identifiable {
        public let id: Int
        /// Speaker id (`mic-1`), or for parsed `live.md` the rendered name.
        public let speaker: String
        public let start: Double
        public let end: Double
        public let text: String
    }

    public let source: Source
    public let lines: [Line]

    public init(source: Source, lines: [Line]) { self.source = source; self.lines = lines }

    public static func load(store: MeetingStore, id: String) -> TranscriptLines {
        if let t = try? store.loadTranscript(id) {
            let cleanup = (try? store.loadCleanup(id)).flatMap { $0 }.flatMap { $0.matches(t) ? $0 : nil }
            var texts = t.utterances.map(\.text)
            if let cleanup {
                for c in cleanup.utterances where texts.indices.contains(c.index) { texts[c.index] = c.text }
            }
            let lines = t.utterances.enumerated().map { i, u in
                Line(id: i, speaker: u.speaker, start: u.start, end: u.end, text: texts[i])
            }
            return TranscriptLines(source: cleanup == nil ? .transcript : .cleanedTranscript, lines: lines)
        }
        if let live = try? store.loadLive(id) {
            let lines = live.lines.enumerated().map { i, l in
                Line(id: i, speaker: l.speaker, start: l.start, end: l.end, text: l.text)
            }
            return TranscriptLines(source: .live, lines: lines)
        }
        if let text = (try? store.readText(id, MeetingStore.liveMarkdownFile)) ?? nil {
            return TranscriptLines(source: .liveMarkdown, lines: parseLiveMarkdown(text))
        }
        return TranscriptLines(source: .none, lines: [])
    }

    /// Lines of the form `[mm:ss] **Name:** text` (or `[h:mm:ss]`), as `LiveRenderer` writes them.
    /// A line's end is the next line's start (the Markdown has no ends).
    public static func parseLiveMarkdown(_ text: String) -> [Line] {
        var parsed: [(String, Double, String)] = []
        for raw in text.split(separator: "\n") {
            let s = raw.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { continue }
            let stamp = s[s.index(after: s.startIndex)..<close]
            let parts = stamp.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 || parts.count == 3 else { continue }
            let seconds = parts.reduce(0) { $0 * 60 + $1 }
            let rest = s[s.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("**"), let end = rest.range(of: ":**") else { continue }
            let name = String(rest[rest.index(rest.startIndex, offsetBy: 2)..<end.lowerBound])
            let body = rest[end.upperBound...].trimmingCharacters(in: .whitespaces)
            parsed.append((name, seconds, body))
        }
        return parsed.enumerated().map { i, p in
            let end = i + 1 < parsed.count ? max(p.1, parsed[i + 1].1) : p.1
            return Line(id: i, speaker: p.0, start: p.1, end: end, text: p.2)
        }
    }

    /// Index of the line playing at `time`: the last line starting at or before it.
    public func index(at time: Double) -> Int? {
        var found: Int?
        for (i, l) in lines.enumerated() {
            if l.start <= time + 0.05 { found = i } else { break }
        }
        return found
    }
}
