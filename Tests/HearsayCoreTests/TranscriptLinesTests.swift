import XCTest
@testable import HearsayCore

final class TranscriptLinesTests: XCTestCase {
    func testParsesLiveMarkdown() {
        let md = """
            # Live transcript

            Updated 2026-10-01T09:30:00.000Z

            [00:03] **Room 1:** Morning, everyone.

            [01:02:05] **Rob:** Thanks: see you.

            not a line
            """
        let lines = TranscriptLines.parseLiveMarkdown(md)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].speaker, "Room 1")
        XCTAssertEqual(lines[0].start, 3)
        XCTAssertEqual(lines[0].end, 3725)
        XCTAssertEqual(lines[0].text, "Morning, everyone.")
        XCTAssertEqual(lines[1].speaker, "Rob")
        XCTAssertEqual(lines[1].start, 3725)
        XCTAssertEqual(lines[1].text, "Thanks: see you.")
    }

    func testRoundTripsLiveRenderer() {
        let live = LiveTranscript(updatedAt: Date(), speakerNames: ["mic-1": "Ana"], lines: [
            LiveLine(speaker: "mic-1", stream: .mic, start: 1, end: 2, text: "Hello there."),
            LiveLine(speaker: "sys-1", stream: .system, start: 65, end: 70, text: "Hi."),
        ])
        let lines = TranscriptLines.parseLiveMarkdown(LiveRenderer.markdown(live))
        XCTAssertEqual(lines.map(\.speaker), ["Ana", "sys-1"])
        XCTAssertEqual(lines.map(\.start), [1, 65])
    }

    func testFixturePrefersTranscriptAndIndexes() throws {
        let store = try TestSupport.rootWithFixture()
        let id = TestSupport.fixtureID
        let t = TranscriptLines.load(store: store, id: id)
        XCTAssertNotEqual(t.source, .none)
        XCTAssertFalse(t.lines.isEmpty)
        XCTAssertNil(t.index(at: -10))
        XCTAssertEqual(t.index(at: t.lines.last!.start + 1), t.lines.count - 1)
    }
}
