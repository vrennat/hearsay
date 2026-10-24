import XCTest
@testable import HearsayCore

final class RetentionTests: XCTestCase {
    let now = TestSupport.date("2026-10-23T12:00:00.000Z")

    func meeting(_ id: String, daysAgo: Double, status: MeetingStatus = .done, audioRemoved: Bool = false) -> Meeting {
        Meeting(id: id, title: id, startedAt: now.addingTimeInterval(-daysAgo * 86_400), status: status,
                streams: [AudioStream(kind: .mic, file: "audio/mic.m4a")],
                audioRemovedAt: audioRemoved ? now : nil)
    }

    func plan(_ inputs: [RetentionPlan.Input], audio: Int = 30, transcript: Int = 365, queued: Set<String> = []) -> RetentionPlan {
        RetentionPlan.make(inputs, now: now, keepAudioDays: audio, keepTranscriptDays: transcript, queued: queued)
    }

    func testDecisionBranches() {
        let p = plan([
            .init(meeting: meeting("young", daysAgo: 10), hasTranscript: true),
            .init(meeting: meeting("audio-old", daysAgo: 40), hasTranscript: true),
            .init(meeting: meeting("no-transcript", daysAgo: 40), hasTranscript: false),
            .init(meeting: meeting("already", daysAgo: 40, audioRemoved: true), hasTranscript: true),
            .init(meeting: meeting("ancient", daysAgo: 400), hasTranscript: false),
            .init(meeting: meeting("recording", daysAgo: 400, status: .recording), hasTranscript: true),
            .init(meeting: meeting("processing", daysAgo: 40, status: .processing), hasTranscript: true),
            .init(meeting: meeting("queued", daysAgo: 40, status: .recorded), hasTranscript: true),
        ], queued: ["queued"])
        XCTAssertEqual(p.items.map(\.id), ["audio-old", "ancient"])
        XCTAssertEqual(p.items.map(\.action), [.removeAudio, .trash])
        XCTAssertEqual(p.skipped, [
            .init(id: "no-transcript", reason: .noTranscript),
            .init(id: "already", reason: .audioAlreadyRemoved),
            .init(id: "recording", reason: .busy),
            .init(id: "processing", reason: .busy),
            .init(id: "queued", reason: .busy),
        ])
    }

    func testZeroMeansForever() {
        let p = plan([.init(meeting: meeting("old", daysAgo: 4000), hasTranscript: true)], audio: 0, transcript: 0)
        XCTAssertEqual(p, RetentionPlan())
    }

    func testUntilTranscribedRemovesAudioAtAnyAge() {
        let p = plan([
            .init(meeting: meeting("fresh", daysAgo: 0), hasTranscript: true),
            .init(meeting: meeting("pending", daysAgo: 0), hasTranscript: false),
        ], audio: RetentionPlan.untilTranscribed, transcript: 0)
        XCTAssertEqual(p.items.map(\.id), ["fresh"])
        XCTAssertEqual(p.items.map(\.action), [.removeAudio])
        XCTAssertEqual(p.skipped, [.init(id: "pending", reason: .noTranscript)])
    }

    func testAudioOnlyLimit() {
        let p = plan([.init(meeting: meeting("old", daysAgo: 4000), hasTranscript: true)], audio: 7, transcript: 0)
        XCTAssertEqual(p.items.map(\.action), [.removeAudio])
    }

    func testApplyRemovesAudioAndTrashes() throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        for (id, days) in [("2026-01-01 0900 Old", 300.0), ("2026-09-01 0900 Mid", 50.0)] {
            var m = meeting(id, daysAgo: days)
            m.id = id
            try FileManager.default.createDirectory(at: store.folder(id).appendingPathComponent("audio"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: store.folder(id).appendingPathComponent("audio/mic.m4a"))
            try store.saveMeeting(m)
            try store.saveTranscript(Transcript(engine: "parakeet", processedAt: now, speakers: [], utterances: []), id: id)
        }
        let p = RetentionPlan.make(store: store, now: now, keepAudioDays: 30, keepTranscriptDays: 200)
        XCTAssertEqual(p.items.map(\.action), [.trash, .removeAudio])
        let done = Retention.apply(p, store: store, now: now)
        XCTAssertEqual(done.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder("2026-01-01 0900 Old").path))
        let mid = try store.loadMeeting("2026-09-01 0900 Mid")
        XCTAssertEqual(mid.streams, [])
        XCTAssertEqual(mid.audioRemovedAt, now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(mid.id).appendingPathComponent("audio").path))
        // A second plan is a no-op for the trimmed meeting.
        XCTAssertEqual(RetentionPlan.make(store: store, now: now, keepAudioDays: 30, keepTranscriptDays: 200).items, [])
    }
}

final class CrashReportsTests: XCTestCase {
    func testListsHearsayReportsNewerThanDate() throws {
        let dir = try TestSupport.tempRoot()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func make(_ name: String, _ offset: TimeInterval) throws {
            let url = dir.appendingPathComponent(name)
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(offset)], ofItemAtPath: url.path)
        }
        try make("Hearsay-2026-10-01-old.ips", -10)
        try make("Hearsay-2026-10-02-new.ips", 10)
        try make("Hearsay-2026-10-03-newer.ips", 20)
        try make("Other-2026-10-02.ips", 10)
        try make("Hearsay-2026-10-02.txt", 10)
        let found = CrashReports.list(in: dir, since: base)
        XCTAssertEqual(found.map(\.url.lastPathComponent), ["Hearsay-2026-10-02-new.ips", "Hearsay-2026-10-03-newer.ips"])
        XCTAssertEqual(found.first?.date, base.addingTimeInterval(10))
        XCTAssertEqual(CrashReports.list(in: dir, since: nil).count, 3)

        let defaults = UserDefaults(suiteName: "hearsay-tests-\(UUID().uuidString)")!
        XCTAssertEqual(CrashReports.newSinceLastCheck(in: dir, defaults: defaults), [])
        CrashReports.markChecked(base.addingTimeInterval(15), defaults)
        XCTAssertEqual(CrashReports.newSinceLastCheck(in: dir, defaults: defaults).map(\.url.lastPathComponent), ["Hearsay-2026-10-03-newer.ips"])
    }
}
