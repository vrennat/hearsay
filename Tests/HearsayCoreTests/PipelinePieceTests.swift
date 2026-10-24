import AVFoundation
import XCTest
@testable import HearsayCore

final class CleanupTests: XCTestCase {
    func testFillersAndRepeats() {
        XCTAssertEqual(TextCleaner.clean("Um, hi there."), "Hi there.")
        XCTAssertEqual(TextCleaner.clean("I I think the the plan works."), "I think the plan works.")
        XCTAssertEqual(TextCleaner.clean("So uh we should, um, ship it."), "So we should ship it.")
        XCTAssertEqual(TextCleaner.clean("I think I think we're done."), "I think we're done.")
        XCTAssertEqual(TextCleaner.clean("That works, uh."), "That works.")
        XCTAssertEqual(TextCleaner.clean("It was so um."), "It was so.")
        XCTAssertEqual(TextCleaner.clean("The the API is fine."), "The API is fine.")
        // Not removed: real words, and repeats across punctuation.
        XCTAssertEqual(TextCleaner.clean("I like it, like, a lot."), "I like it, like, a lot.")
        XCTAssertEqual(TextCleaner.clean("No. No, that is wrong."), "No. No, that is wrong.")
        XCTAssertEqual(TextCleaner.clean("Hummus and umbrellas."), "Hummus and umbrellas.")
    }

    func testCleanupJSONMatchesTranscript() {
        let (_, t) = TestSupport.smallMeeting()
        let c = TextCleaner.cleanup(for: t)
        XCTAssertTrue(c.matches(t))
        XCTAssertEqual(c.method, "hearsay")
        XCTAssertEqual(c.utterances.map(\.text), ["Hi there.", "Hello, hello again."])
    }
}

final class AttributionTests: XCTestCase {
    func testOverlapNearestAndRanking() {
        let segs = [DiarSegment(slot: "A", start: 0, end: 2), DiarSegment(slot: "B", start: 2, end: 10), DiarSegment(slot: "A", start: 10, end: 11)]
        XCTAssertEqual(Attribution.slot(for: Word(text: "x", start: 1.5, end: 2.2), in: segs), "A")
        XCTAssertEqual(Attribution.slot(for: Word(text: "x", start: 1.8, end: 2.5), in: segs), "B")
        XCTAssertEqual(Attribution.slot(for: Word(text: "x", start: 11.2, end: 11.4), in: segs), "A")
        XCTAssertEqual(Attribution.slot(for: Word(text: "x", start: 0, end: 1), in: []), "0")

        let words = [Word(text: "Hi.", start: 0.2, end: 0.6), Word(text: "Long", start: 3, end: 3.5), Word(text: "talk", start: 3.6, end: 4),
                     Word(text: "here.", start: 4.1, end: 5), Word(text: "Bye.", start: 10.2, end: 10.6)]
        let (speakers, utts) = Attribution.build(words: words, segments: segs, stream: .system)
        XCTAssertEqual(speakers.map(\.id), ["sys-1", "sys-2"])
        XCTAssertEqual(speakers.map(\.defaultLabel), ["Remote 1", "Remote 2"])
        XCTAssertEqual(utts.map(\.speaker), ["sys-2", "sys-1", "sys-2"])
        XCTAssertEqual(utts[1].text, "Long talk here.")
        XCTAssertEqual(speakers[0].talkSeconds, 2, accuracy: 1e-9)
    }

    func testCleanSpansSkipOverlapAndShortTurns() {
        let u = [
            Utterance(speaker: "mic-1", stream: .mic, start: 0, end: 3, text: "a"),
            Utterance(speaker: "mic-2", stream: .mic, start: 2.5, end: 4, text: "b"),
            Utterance(speaker: "mic-1", stream: .mic, start: 5, end: 6, text: "short"),
            Utterance(speaker: "mic-1", stream: .mic, start: 10, end: 80, text: "long"),
            Utterance(speaker: "sys-1", stream: .system, start: 10, end: 20, text: "other stream is fine"),
        ]
        let spans = Attribution.cleanSpans(for: "mic-1", in: u)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].0, 10); XCTAssertEqual(spans[0].1, 70)
    }
}

final class LoudnessTests: XCTestCase {
    func testCurveAndGate() {
        let loud = [Float](repeating: 0.1, count: 1600)  // -20 dBFS
        let c = Loudness.curve(loud + [Float](repeating: 0, count: 1600))
        XCTAssertEqual(c.count, 20)
        XCTAssertEqual(c[0], -20, accuracy: 0.01)
        XCTAssertEqual(c[19], Loudness.floorDBFS)
        XCTAssertEqual(Loudness.meetingCurve(loud, startOffset: 0.5).count, 60)

        func curve(loud: Int, quiet: Int) -> [Float] { [Float](repeating: -30, count: loud) + [Float](repeating: -60, count: quiet) }
        XCTAssertTrue(Loudness.passesGate(curve(loud: 2000, quiet: 100_000)))   // 20 s loud in 17 min
        XCTAssertFalse(Loudness.passesGate(curve(loud: 1990, quiet: 100_000)))
        XCTAssertTrue(Loudness.passesGate(curve(loud: 250, quiet: 750)))        // 2.5 of 10 s
        XCTAssertFalse(Loudness.passesGate(curve(loud: 240, quiet: 760)))
        XCTAssertFalse(Loudness.passesGate([]))
        // Short tracks need 3 s (a 49 s test with a few sentences); mid-length 5%; long ones 20 s.
        XCTAssertTrue(Loudness.passesGate(curve(loud: 300, quiet: 4600)))        // 3.0 of 49 s
        XCTAssertFalse(Loudness.passesGate(curve(loud: 290, quiet: 4610)))
        XCTAssertEqual(Loudness.requiredLoudSeconds(duration: 120), 6)
        XCTAssertEqual(Loudness.requiredLoudSeconds(duration: 714), 20)
        XCTAssertEqual(Loudness.requiredLoudSeconds(duration: 8), 2)
        // The gate line follows the track's noise floor: a quiet interface (floor -63, speech -50)
        // passes; a hot room (floor -40) is still held at the fixed -46 line; padding is ignored.
        let quietMic = [Float](repeating: -50, count: 600) + [Float](repeating: -63, count: 5400)
        XCTAssertEqual(Loudness.gateThreshold(quietMic), -53)
        XCTAssertTrue(Loudness.passesGate(quietMic))
        XCTAssertEqual(Loudness.gateThreshold([Float](repeating: -40, count: 100)), Loudness.loudDBFS)
        XCTAssertEqual(Loudness.gateThreshold([Float](repeating: Loudness.floorDBFS, count: 500) + [Float](repeating: -90, count: 100)), Loudness.gateFloorDBFS)
        XCTAssertEqual(Loudness.gateThreshold([]), Loudness.loudDBFS)
        // -46 itself is not loud.
        XCTAssertEqual(Loudness.loudSeconds([-46, -45.9]), 0.01, accuracy: 1e-9)
    }
}

final class HeardStreamsTests: XCTestCase {
    func testLiveWordsBypassGate() {
        let t = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ProcessPipeline.heardStreams(nil), [])
        let live = LiveTranscript(updatedAt: t, lines: [
            LiveLine(speaker: "mic-1", stream: .mic, start: 0, end: 1, text: "Hello, test recording."),
            LiveLine(speaker: "system-1", stream: .system, start: 0, end: 1, text: "  "),
        ])
        XCTAssertEqual(ProcessPipeline.heardStreams(live), [.mic])
    }
}

final class TitlerTests: XCTestCase {
    func testTitles() {
        let start = TestSupport.date("2026-10-22T16:05:00.000Z")
        var m = Meeting(id: "x", title: "", startedAt: start)
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(Titler.title(for: m, timeZone: utc), "2026-10-22 16:05 Meeting")
        m.title = "New meeting"
        XCTAssertEqual(Titler.title(for: m, timeZone: utc), "2026-10-22 16:05 Meeting")
        m.title = "Rob / Tanner"
        XCTAssertEqual(Titler.title(for: m, timeZone: utc), "Rob / Tanner")
    }
}

final class CompressionTests: XCTestCase {
    func testCompressesWithinTolerance() async throws {
        let root = try TestSupport.tempRoot()
        let src = root.appendingPathComponent("tone.wav")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        do {
            let f = try AVAudioFile(forWriting: src, settings: fmt.settings)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 48_000 * 3)!
            buf.frameLength = buf.frameCapacity
            for ch in 0..<2 { for i in 0..<Int(buf.frameLength) { buf.floatChannelData![ch][i] = 0.3 * sin(Float(i) * 0.05) } }
            try f.write(from: buf)
        }
        let out = root.appendingPathComponent("tone.m4a")
        try await AudioCompressor.compress(src, to: out)
        XCTAssertEqual(try AudioCompressor.duration(out), 3, accuracy: AudioCompressor.tolerance)
        XCTAssertLessThan(try FileManager.default.attributesOfItem(atPath: out.path)[.size] as! Int, 3 * 128_000 / 8 + 20_000)

        // Four discrete channels (an audio interface, mic on input 1): folded to mono, same length.
        let quad = root.appendingPathComponent("quad.caf")
        let quadLayout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)!
        let quadFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: quadLayout)
        do {
            let f = try AVAudioFile(forWriting: quad, settings: quadFmt.settings)
            let buf = AVAudioPCMBuffer(pcmFormat: quadFmt, frameCapacity: 48_000 * 2)!
            buf.frameLength = buf.frameCapacity
            for i in 0..<Int(buf.frameLength) { buf.floatChannelData![0][i] = 0.3 * sin(Float(i) * 0.05) }
            try f.write(from: buf)
        }
        let quadOut = root.appendingPathComponent("quad.m4a")
        try await AudioCompressor.compress(quad, to: quadOut)
        XCTAssertEqual(try AudioCompressor.duration(quadOut), 2, accuracy: AudioCompressor.tolerance)
        XCTAssertEqual(try AVAudioFile(forReading: quadOut).fileFormat.channelCount, 1)
        // The fold keeps the live input at full level (a mean over all four would be 0.075).
        let decoded = try AVAudioFile(forReading: quadOut)
        let dec = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: AVAudioFrameCount(decoded.length))!
        try decoded.read(into: dec)
        let peak = (0..<Int(dec.frameLength)).reduce(Float(0)) { max($0, abs(dec.floatChannelData![0][$1])) }
        XCTAssertEqual(peak, 0.3, accuracy: 0.05)

        // Meeting-level: repoints meeting.json, deletes the original, skips an .m4a stream.
        let store = MeetingStore(root: root)
        let id = "2026-10-22 0900 C"
        try FileManager.default.createDirectory(at: store.folder(id).appendingPathComponent("audio"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src, to: store.folder(id).appendingPathComponent("audio/mic.wav"))
        try FileManager.default.copyItem(at: out, to: store.folder(id).appendingPathComponent("audio/system.m4a"))
        try store.saveMeeting(Meeting(id: id, title: "C", startedAt: Date(), status: .done,
                                      streams: [AudioStream(kind: .mic, file: "audio/mic.wav"), AudioStream(kind: .system, file: "audio/system.m4a", startOffset: 1)]))
        let n = try await AudioCompressor.compressMeeting(id, store: store)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(try store.loadMeeting(id).streams.map(\.file), ["audio/mic.m4a", "audio/system.m4a"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(id).appendingPathComponent("audio/mic.wav").path))
    }
}

final class ProcessGuardTests: XCTestCase {
    func testRefusesRemovedAudioWithoutTouchingStatus() async throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let m = Meeting(id: "2026-10-22 0900 Old", title: "Old", startedAt: Date(), status: .done, audioRemovedAt: Date())
        try FileManager.default.createDirectory(at: store.folder(m.id), withIntermediateDirectories: true)
        try store.saveMeeting(m)
        do {
            try await ProcessPipeline.process(meetingID: m.id, store: store)
            XCTFail("expected refusal")
        } catch ProcessError.audioRemoved {}
        XCTAssertEqual(try store.loadMeeting(m.id).status, .done)
    }

    /// The fixture folder has a transcript but no audio/: processing keeps it as it is.
    func testRefusesMissingAudioWhenTranscribed() async throws {
        let store = try TestSupport.rootWithFixture()
        do {
            try await ProcessPipeline.process(meetingID: TestSupport.fixtureID, store: store)
            XCTFail("expected refusal")
        } catch ProcessError.audioMissing {}
        let m = try store.loadMeeting(TestSupport.fixtureID)
        XCTAssertEqual(m.status, .done)
        XCTAssertNil(m.error)
    }
}
