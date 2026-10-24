import Foundation
import Testing
@testable import HearsayCore

@Suite struct IndexTests {
    @Test func indexListsNewestFirst() throws {
        let store = try TestSupport.rootWithFixture()
        let (m, t) = TestSupport.smallMeeting()
        try store.saveMeeting(m)
        try store.saveTranscript(t, id: m.id)
        var bare = Meeting(id: "2026-09-01 0800 Recording", title: "", startedAt: TestSupport.date("2026-09-01T08:00:00.000Z"))
        bare.status = .recording
        try store.saveMeeting(bare)

        try IndexRenderer.reindex(store: store)

        let md = try String(contentsOf: store.root.appendingPathComponent("index.md"), encoding: .utf8)
        let rows = md.split(separator: "\n").filter { $0.hasPrefix("| 2026") }
        #expect(rows.count == 3)
        #expect(rows[0].contains("Small: sync") && rows[0].contains("02:05") && rows[0].contains("1/2") && rows[0].contains("done"))
        #expect(rows[1].contains("Fixture standup") && rows[1].contains("2/2"))
        #expect(rows[2].contains("2026-09-01 0800 Recording") && rows[2].contains("recording"))

        let lines = try String(contentsOf: store.root.appendingPathComponent("index.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 3)
        let first = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(first["id"] as? String == m.id)
        #expect(first["named"] as? Bool == false)
        #expect(first["path"] as? String == "\(m.id)/transcript.md")
        #expect((first["speakers"] as? [Any])?.count == 2)
        for key in ["title", "startedAt", "endedAt", "status"] { #expect(first[key] != nil) }

        // Markdown was regenerated for every meeting with a transcript
        #expect(FileManager.default.fileExists(atPath: store.folder(m.id).appendingPathComponent("transcript.md").path))
        #expect(!FileManager.default.fileExists(atPath: store.folder(bare.id).appendingPathComponent("transcript.md").path))
    }
}
