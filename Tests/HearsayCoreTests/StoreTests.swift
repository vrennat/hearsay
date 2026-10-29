import Foundation
import Testing
@testable import HearsayCore

@Suite struct StoreTests {
    @Test func fixtureDecodesDespiteUnknownKeysAndMissingOptionals() throws {
        let store = try TestSupport.rootWithFixture()
        let id = TestSupport.fixtureID
        let m = try store.loadMeeting(id)
        #expect(m.id == id)  // folder name wins over the stored id
        #expect(m.status == .done)
        #expect(m.streams.count == 2)
        #expect(m.streams[1].startOffset == 1.5)
        #expect(m.streams[1].sampleRate == nil)
        #expect(m.echoCancellation == nil)
        #expect(m.audioRemovedAt == nil)
        #expect(m.speakerNames["sys-1"] == "Priya")
        #expect(m.duration.map { abs($0 - 65.5) < 0.001 } == true)

        let t = try #require(try store.loadTranscript(id))
        #expect(t.speakers.count == 3)
        #expect(t.speakers[0].voice == [0.1, -0.2, 0.3])
        #expect(t.speakers[1].voice == nil)
        #expect(t.utterances[1].words.isEmpty)
        #expect(t.utterances[0].words.count == 7)

        let c = try #require(try store.loadCleanup(id))
        #expect(c.matches(t))
        #expect(c.utterances.count == 2)

        let live = try #require(try store.loadLive(id))
        #expect(live.lines.count == 2)
        #expect(live.lines[1].stream == .system)  // inferred from sys- id
    }

    @Test func roundTripsAllFourFiles() throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let (meeting, transcript) = TestSupport.smallMeeting()
        var m = meeting
        m.streams = [AudioStream(kind: .mic, file: "audio/mic.m4a", startOffset: 0.25, sampleRate: 48_000, channels: 1)]
        m.audioRemovedAt = TestSupport.date("2026-10-05T01:02:03.456Z")
        try store.saveMeeting(m)
        try store.saveTranscript(transcript, id: m.id)
        let cleanup = Cleanup(sourceProcessedAt: transcript.processedAt, method: "fillers",
                              utterances: [CleanedUtterance(index: 0, text: "Hi there.")])
        try store.saveCleanup(cleanup, id: m.id)
        let live = LiveTranscript(updatedAt: TestSupport.date("2026-10-02T10:01:00.100Z"),
                                  speakerNames: ["mic-1": "Tanner"],
                                  lines: [LiveLine(speaker: "mic-1", stream: .mic, start: 1, end: 2, text: "hi")])
        let meetingBefore = try Data(contentsOf: store.folder(m.id).appendingPathComponent("meeting.json"))
        try store.saveLive(live, id: m.id)

        #expect(try store.loadMeeting(m.id) == m)
        #expect(try store.loadTranscript(m.id) == transcript)
        #expect(try store.loadCleanup(m.id) == cleanup)
        #expect(try store.loadLive(m.id) == live)
        // live writers leave meeting.json alone
        #expect(try Data(contentsOf: store.folder(m.id).appendingPathComponent("meeting.json")) == meetingBefore)
        let liveMD = try String(contentsOf: store.folder(m.id).appendingPathComponent("live.md"), encoding: .utf8)
        #expect(liveMD.contains("[00:01] **Tanner:** hi"))
        // fractional seconds survive
        let raw = try String(contentsOf: store.folder(m.id).appendingPathComponent("transcript.json"), encoding: .utf8)
        #expect(raw.contains("10:00:00.500"))
        // a second save/load cycle is byte-stable
        let again = try store.loadMeeting(m.id)
        try store.saveMeeting(again)
        #expect(try store.loadMeeting(m.id) == m)
        // no temp files left behind
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.folder(m.id).path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func prepareSeedsOnlyWhenMissing() throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        try store.prepare()
        let guide = store.root.appendingPathComponent("CLAUDE.md")
        let glossary = store.root.appendingPathComponent("glossary.txt")
        #expect(FileManager.default.fileExists(atPath: guide.path))
        #expect(try String(contentsOf: glossary, encoding: .utf8).contains("=>"))
        try "mine".write(to: glossary, atomically: true, encoding: .utf8)
        try store.prepare()
        #expect(try String(contentsOf: glossary, encoding: .utf8) == "mine")
    }

    @Test func meetingIDsAreStableAndUnique() throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 23; c.hour = 9; c.minute = 5
        let d = try #require(Calendar.current.date(from: c))
        let id = store.newMeetingID(startedAt: d, title: "Design / review: Q4!")
        #expect(id == "2026-10-23 0905 Design review Q4")
        try FileManager.default.createDirectory(at: store.folder(id), withIntermediateDirectories: true)
        #expect(store.newMeetingID(startedAt: d, title: "Design / review: Q4!") == "\(id)-2")
    }
}
