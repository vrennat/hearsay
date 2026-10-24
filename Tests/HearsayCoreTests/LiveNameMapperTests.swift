import XCTest
@testable import HearsayCore

final class LiveNameMapperTests: XCTestCase {
    typealias M = LiveNameMapper
    func span(_ a: Double, _ b: Double) -> M.Span { M.Span(a, b) }

    func testOneToOne() {
        let live = [M.LiveVoice(id: "mic-1", stream: .mic, name: "Tanner", spans: [span(0, 10)]),
                    M.LiveVoice(id: "sys-1", stream: .system, name: "Priya", spans: [span(10, 20)])]
        let final = [M.FinalVoice(id: "mic-2", stream: .mic, spans: [span(0, 9)]),
                     M.FinalVoice(id: "sys-1", stream: .system, spans: [span(10, 20)])]
        XCTAssertEqual(M.map(live: live, final: final), ["mic-2": "Tanner", "sys-1": "Priya"])
    }

    func testTwoLiveVoicesToOneFinalSpeakerOnlyBestGetsName() {
        let live = [M.LiveVoice(id: "sys-1", stream: .system, name: "Nate", spans: [span(0, 10)]),
                    M.LiveVoice(id: "sys-2", stream: .system, name: "Nathan", spans: [span(10, 20)])]
        // Final sys-1 covers all of live sys-2 and 60% of live sys-1.
        let final = [M.FinalVoice(id: "sys-1", stream: .system, spans: [span(4, 20)])]
        XCTAssertEqual(M.map(live: live, final: final), ["sys-1": "Nathan"])
    }

    func testUnderHalfCoverageStaysUnnamed() {
        let live = [M.LiveVoice(id: "mic-1", stream: .mic, name: "Tanner", spans: [span(0, 10)])]
        let final = [M.FinalVoice(id: "mic-1", stream: .mic, spans: [span(0, 5)]),
                     M.FinalVoice(id: "mic-2", stream: .mic, spans: [span(5, 10)])]
        XCTAssertEqual(M.map(live: live, final: final), [:])
    }

    func testCrossStreamNeverMatches() {
        let live = [M.LiveVoice(id: "mic-1", stream: .mic, name: "Tanner", spans: [span(0, 10)])]
        let final = [M.FinalVoice(id: "sys-1", stream: .system, spans: [span(0, 10)])]
        XCTAssertEqual(M.map(live: live, final: final), [:])
    }

    func testFromOnDiskModels() {
        let live = LiveTranscript(updatedAt: Date(), speakerNames: ["mic-1": "Tanner"], lines: [
            LiveLine(speaker: "mic-1", stream: .mic, start: 0, end: 4, text: "hi"),
            LiveLine(speaker: "mic-1", stream: .mic, start: 6, end: 8, text: "ok"),
            LiveLine(speaker: "mic-2", stream: .mic, start: 9, end: 12, text: "yes"),
        ])
        let t = Transcript(engine: "parakeet", processedAt: Date(), speakers: [
            Speaker(id: "mic-1", stream: .mic, defaultLabel: "Me", talkSeconds: 6),
            Speaker(id: "mic-2", stream: .mic, defaultLabel: "Room 2", talkSeconds: 3),
        ], utterances: [
            Utterance(speaker: "mic-2", stream: .mic, start: 0, end: 8, text: "hi ok"),
            Utterance(speaker: "mic-1", stream: .mic, start: 9, end: 12, text: "yes"),
        ])
        XCTAssertEqual(M.map(live: live, transcript: t), ["mic-2": "Tanner"])
    }
}

final class LiveEchoGateTests: XCTestCase {
    func testWindowWaitsForBothStreamsOneSecondPast() {
        var g = LiveEchoGate()
        XCTAssertEqual(g.readyWindows(micAudioEnd: 10, systemAudioEnd: nil), [])
        XCTAssertEqual(g.readyWindows(micAudioEnd: 10, systemAudioEnd: 2.49), [])
        XCTAssertEqual(g.readyWindows(micAudioEnd: 10, systemAudioEnd: 2.5), [0])  // 1.5 + 1
        XCTAssertEqual(g.readyWindows(micAudioEnd: 3.99, systemAudioEnd: 10), [])
        XCTAssertEqual(g.readyWindows(micAudioEnd: 5.5, systemAudioEnd: 10), [1, 2])  // windows end 3.0, 4.5
        XCTAssertEqual(g.nextWindow, 3)
    }
}
