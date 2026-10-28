import XCTest
@testable import HearsayCore

final class ReassignTests: XCTestCase {
    func make() throws -> (MeetingStore, String, Date) {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let id = "m"
        try FileManager.default.createDirectory(at: store.folder(id), withIntermediateDirectories: true)
        try store.saveMeeting(Meeting(id: id, title: "m", startedAt: Date(), status: .done,
                                      speakerNames: ["sys-1": "Reese", "sys-2": "Tyler"]))
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let u = [Utterance(speaker: "sys-1", stream: .system, start: 0, end: 10, text: "a"),
                 Utterance(speaker: "sys-1", stream: .system, start: 10, end: 12, text: "b"),
                 Utterance(speaker: "sys-2", stream: .system, start: 12, end: 15, text: "c"),
                 Utterance(speaker: "mic-1", stream: .mic, start: 15, end: 20, text: "d")]
        let sp = [Speaker(id: "sys-1", stream: .system, defaultLabel: "Remote 1", talkSeconds: 12),
                  Speaker(id: "sys-2", stream: .system, defaultLabel: "Remote 2", talkSeconds: 3),
                  Speaker(id: "mic-1", stream: .mic, defaultLabel: "Room 1", talkSeconds: 5)]
        try store.saveTranscript(Transcript(engine: "parakeet", processedAt: at, speakers: sp, utterances: u), id: id)
        try store.saveCleanup(Cleanup(sourceProcessedAt: at, utterances: [.init(index: 1, text: "B cleaned")]), id: id)
        return (store, id, at)
    }

    func testMoveToNewSpeakerKeepsCleanupAndRecomputesTalk() throws {
        let (store, id, at) = try make()
        let dest = try MeetingEdits.reassign(id: id, utterances: [1], to: nil, store: store)
        XCTAssertEqual(dest, "sys-3")
        let t = try XCTUnwrap(try store.loadTranscript(id))
        XCTAssertEqual(t.processedAt, at)
        XCTAssertEqual(t.utterances.map(\.speaker), ["sys-1", "sys-3", "sys-2", "mic-1"])
        XCTAssertEqual(t.speaker("sys-1")?.talkSeconds, 10)
        XCTAssertEqual(t.speaker("sys-3")?.talkSeconds, 2)
        XCTAssertEqual(t.speaker("sys-3")?.defaultLabel, "Remote 3")
        // The cleaned text still applies: same processedAt, same index.
        let lines = TranscriptLines.load(store: store, id: id)
        XCTAssertEqual(lines.lines[1].text, "B cleaned")
        XCTAssertEqual(lines.lines[1].speaker, "sys-3")
    }

    func testMovingTheLastLineRemovesTheSpeakerAndItsName() throws {
        let (store, id, _) = try make()
        try MeetingEdits.reassign(id: id, utterances: [2], to: "sys-1", store: store)
        let t = try XCTUnwrap(try store.loadTranscript(id))
        XCTAssertNil(t.speaker("sys-2"))
        XCTAssertEqual(t.speaker("sys-1")?.talkSeconds, 15)
        XCTAssertEqual(try store.loadMeeting(id).speakerNames, ["sys-1": "Reese"])
    }

    func testRoomAndCallNeverMix() throws {
        let (store, id, _) = try make()
        XCTAssertThrowsError(try MeetingEdits.reassign(id: id, utterances: [3], to: "sys-1", store: store))
        XCTAssertThrowsError(try MeetingEdits.reassign(id: id, utterances: [0, 3], to: nil, store: store))
        XCTAssertThrowsError(try MeetingEdits.reassign(id: id, utterances: [99], to: nil, store: store))
    }
}
