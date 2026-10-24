import Foundation

/// `index.md` (newest first) and `index.jsonl`, regenerated from every meeting folder.
public enum IndexRenderer {
    public struct Entry: Codable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let startedAt: Date
        public let endedAt: Date?
        public let status: MeetingStatus
        public let speakers: [SpeakerSummary]
        public let named: Bool
        public let path: String
    }

    public static func entries(store: MeetingStore) -> [Entry] {
        // With transcript encryption on, the index keeps titles, dates and status only: no speakers.
        let textFree = store.transcriptsEncrypted
        return store.loadAllMeetings().map { m in
            let t = textFree ? nil : (try? store.loadTranscript(m.id)) ?? nil
            let speakers = t.map { SpeakerSummary.summarize($0, names: m.speakerNames) } ?? []
            return Entry(
                id: m.id, title: m.title, startedAt: m.startedAt, endedAt: m.endedAt, status: m.status,
                speakers: speakers, named: SpeakerSummary.allNamed(speakers), path: "\(m.id)/transcript.md\(textFree ? ".enc" : "")")
        }
        .sorted { $0.startedAt != $1.startedAt ? $0.startedAt > $1.startedAt : $0.id > $1.id }
    }

    public static func markdown(_ entries: [Entry]) -> String {
        var out = "# Meetings\n\n| Date | Title | Duration | Speakers named | Status |\n|---|---|---|---|---|\n"
        for e in entries {
            let duration = e.endedAt.map { Format.clock($0.timeIntervalSince(e.startedAt)) } ?? ""
            let main = e.speakers.filter(\.main)
            let named = "\(main.filter { $0.name != nil }.count)/\(main.count)"
            let link = "[\(cell(e.title.isEmpty ? e.id : e.title))](<\(e.path)>)"
            out += "| \(Format.shortDate(e.startedAt)) | \(link) | \(duration) | \(named) | \(e.status.rawValue) |\n"
        }
        return out
    }

    public static func jsonl(_ entries: [Entry]) throws -> String {
        let enc = JSONCoding.encoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try entries.map { String(decoding: try enc.encode($0), as: UTF8.self) + "\n" }.joined()
    }

    private static func cell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    /// Regenerates every meeting's Markdown, then the index.
    public static func reindex(store: MeetingStore) throws {
        try store.prepare()
        for id in store.listMeetingIDs() {
            do { try TranscriptRenderer.write(store: store, id: id) } catch {
                HearsayCore.logger("index").error("Render failed for \(id, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        let e = entries(store: store)
        try AtomicFile.write(markdown(e), to: store.root.appendingPathComponent("index.md"))
        try AtomicFile.write(jsonl(e), to: store.root.appendingPathComponent("index.jsonl"))
    }
}
