import Foundation

/// Generates `transcript.md` and `transcript.raw.md` from `transcript.json` plus `meeting.json`.
/// The Markdown is never edited in place, only regenerated.
public enum TranscriptRenderer {
    public struct Output: Sendable, Equatable {
        public let markdown: String
        public let raw: String
        public let cleanupApplied: Bool
    }

    public static func render(meeting: Meeting, transcript: Transcript, cleanup: Cleanup?) -> Output {
        let applied = cleanup.flatMap { $0.matches(transcript) ? $0 : nil }
        let speakers = SpeakerSummary.summarize(transcript, names: meeting.speakerNames)
        let verbatim = transcript.utterances.map(\.text)
        var cleaned = verbatim
        if let applied {
            for c in applied.utterances where cleaned.indices.contains(c.index) { cleaned[c.index] = c.text }
        }
        let md = frontMatter(meeting, transcript, speakers, cleanedBy: applied.map { $0.method ?? "hearsay" })
            + body(transcript, speakers, cleaned)
        let raw = frontMatter(meeting, transcript, speakers, cleanedBy: nil) + body(transcript, speakers, verbatim)
        return Output(markdown: md, raw: raw, cleanupApplied: applied != nil)
    }

    /// Renders and writes both files for one meeting. Returns false when there is no transcript yet.
    @discardableResult
    public static func write(store: MeetingStore, id: String) throws -> Bool {
        let meeting = try store.loadMeeting(id)
        guard let transcript = try store.loadTranscript(id) else { return false }
        let cleanup = try? store.loadCleanup(id)
        let out = render(meeting: meeting, transcript: transcript, cleanup: cleanup ?? nil)
        try store.writeText(out.markdown, id: id, name: "transcript.md")
        try store.writeText(out.raw, id: id, name: "transcript.raw.md")
        return true
    }

    static func frontMatter(_ m: Meeting, _ t: Transcript, _ speakers: [SpeakerSummary], cleanedBy: String?) -> String {
        var y = "---\n"
        y += "title: \(Format.quoted(m.title))\n"
        y += "started: \(Format.date(m.startedAt))\n"
        if let e = m.endedAt { y += "ended: \(Format.date(e))\n" }
        if let d = m.duration { y += "duration: \(Format.quoted(Format.clock(d)))\n" }
        y += "engine: \(t.engine)\n"
        y += "status: \(m.status.rawValue)\n"
        y += "named: \(SpeakerSummary.allNamed(speakers))\n"
        if let cleanedBy { y += "cleaned_by: \(Format.quoted(cleanedBy))\n" }
        if m.attendees.isEmpty {
            y += "attendees: []\n"
        } else {
            y += "attendees:\n" + m.attendees.map { "  - \(Format.quoted($0))\n" }.joined()
        }
        if speakers.isEmpty {
            y += "speakers: []\n"
        } else {
            y += "speakers:\n"
            for s in speakers {
                y += "  - id: \(s.id)\n"
                y += "    name: \(s.name.map(Format.quoted) ?? "null")\n"
                y += "    label: \(Format.quoted(s.label))\n"
                y += "    talk_time: \(Format.quoted(Format.clock(s.talkSeconds)))\n"
            }
        }
        return y + "---\n\n"
    }

    static func body(_ t: Transcript, _ speakers: [SpeakerSummary], _ texts: [String]) -> String {
        var names: [String: String] = [:]
        for s in speakers { names[s.id] = s.displayName }
        var out = "# \(t.utterances.isEmpty ? "No speech" : "Transcript")\n\n"
        for (i, u) in t.utterances.enumerated() {
            let text = texts[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out += "[\(Format.clock(u.start))] **\(names[u.speaker] ?? u.speaker):** \(text)\n\n"
        }
        return out
    }
}
