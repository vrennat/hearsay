import XCTest
@testable import HearsayCore

/// `Fixtures/2026-09-15 1400 Old app sync` imitates the old app's files as `docs/SPEC.md` describes
/// them (Whisper engine, echoCancellation, appVersion, room-on-call `sys-*` ids, no voices, a stale
/// cleanup, epoch `endedAt`, `word` keys, no `stream` fields). Spec-derived, not a real old folder.
final class OldFormatTests: XCTestCase {
    static let oldID = "2026-09-15 1400 Old app sync"

    func testLoadsRendersAndReindexes() throws {
        let store = try TestSupport.rootWithFixture([Self.oldID, TestSupport.fixtureID])
        let m = try store.loadMeeting(Self.oldID)
        XCTAssertEqual(m.status, .done)
        XCTAssertEqual(m.engine, "whisper")
        XCTAssertNotNil(m.endedAt)
        let t = try XCTUnwrap(try store.loadTranscript(Self.oldID))
        XCTAssertEqual(t.speakers.map(\.stream), [.system, .system])
        XCTAssertEqual(t.utterances.map(\.stream), [.system, .system, .system])
        XCTAssertEqual(t.utterances[0].words.first?.text, "Thanks")
        XCTAssertNil(t.speakers[0].voice)
        XCTAssertNotNil(try store.loadLive(Self.oldID))

        try IndexRenderer.reindex(store: store)
        let folder = store.folder(Self.oldID)
        let md = try String(contentsOf: folder.appendingPathComponent("transcript.md"), encoding: .utf8)
        XCTAssertTrue(md.contains("Sure. Um, the the release is ready."), "stale cleanup must be ignored")
        XCTAssertFalse(md.contains("STALE"))
        XCTAssertFalse(md.contains("cleaned_by:"))
        XCTAssertTrue(md.contains("\"Nate\""))
        let index = try String(contentsOf: store.root.appendingPathComponent("index.jsonl"), encoding: .utf8)
        XCTAssertEqual(index.split(separator: "\n").count, 2)
        XCTAssertTrue(index.contains("Old app sync"))
    }

    /// `voices --apply` with no audio on disk: no embeddings, names kept, nothing thrown.
    func testVoicesApplyTolerates() async throws {
        let store = try TestSupport.rootWithFixture([Self.oldID])
        let rows = try await VoiceBackfill.run(store: store, userName: "Tanner", apply: true)
        XCTAssertEqual(rows.map(\.speaker), ["sys-1", "sys-2"])
        XCTAssertEqual(rows.map(\.voice), ["no voice", "no voice"])
        XCTAssertEqual(try store.loadMeeting(Self.oldID).speakerNames, ["sys-1": "Tanner", "sys-2": "Nate"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.folder(Self.oldID).appendingPathComponent("transcript.md").path))
    }
}
