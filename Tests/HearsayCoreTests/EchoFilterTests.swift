import XCTest
@testable import HearsayCore

final class EchoFilterTests: XCTestCase {
    /// Deterministic speech-like 10 ms loudness: syllables at about -20 dBFS with short gaps and pauses.
    static func speechCurve(frames: Int, seed: UInt64) -> [Float] {
        var rng = seed
        func next() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(rng >> 11) / Double(1 << 53) }
        var out: [Float] = []
        while out.count < frames {
            let syllable = 8 + Int(next() * 22)
            let level = Float(-28 + next() * 16)
            for _ in 0..<syllable { out.append(level + Float(next() * 4 - 2)) }
            let gap = next() < 0.1 ? 30 + Int(next() * 40) : 3 + Int(next() * 12)
            for _ in 0..<gap { out.append(-80 + Float(next() * 6)) }
        }
        return Array(out.prefix(frames))
    }

    static func words(_ prefix: String, every: Double, until: Double, shift: Double = 0) -> [Word] {
        stride(from: 0.2, to: until, by: every).enumerated().map {
            Word(text: "\(prefix)\($0.offset)", start: $0.element + shift, end: $0.element + shift + 0.25)
        }
    }

    /// The same words with the same text, `shift` seconds later (the echo transcribes the same speech).
    static func echoed(_ w: [Word], shift: Double) -> [Word] { w.map { Word(text: $0.text, start: $0.start + shift, end: $0.end + shift) } }

    func delayed(_ c: [Float], frames: Int, gain: Float) -> [Float] {
        [Float](repeating: -90, count: frames) + c.map { $0 + gain }
    }

    func testRoomOnCallDropsSystemWords() {
        let mic = Self.speechCurve(frames: 3000, seed: 1)
        let sys = Array(delayed(mic, frames: 30, gain: -6).prefix(3000))
        let mw = Self.words("w", every: 0.4, until: 29)
        let sw = Self.echoed(mw, shift: 0.3)
        let r = EchoFilter.run(micCurve: mic, sysCurve: sys, mic: mw, sys: sw)
        XCTAssertEqual(r.droppedMic, 0)
        XCTAssertEqual(r.sys.count, 0, "kept \(r.sys.map(\.text))")
        XCTAssertGreaterThan(r.confirmedWindows, 15)
    }

    func testSpeakerEchoDropsMicWords() {
        let sys = Self.speechCurve(frames: 3000, seed: 2)
        let mic = Array(delayed(sys, frames: 30, gain: -10).prefix(3000))
        let sw = Self.words("w", every: 0.4, until: 29)
        let mw = Self.echoed(sw, shift: 0.3)
        let r = EchoFilter.run(micCurve: mic, sysCurve: sys, mic: mw, sys: sw)
        XCTAssertEqual(r.droppedSys, 0)
        XCTAssertEqual(r.mic.count, 0, "kept \(r.mic.map(\.text))")
    }

    func testShortLatencySpeakerEchoDropsMicWords() {
        // Speakers into the mic arrive a few frames late; under 0.1 s means the mic's words go.
        let sys = Self.speechCurve(frames: 1500, seed: 5)
        let mic = Array(delayed(sys, frames: 3, gain: -12).prefix(1500))
        let sw = Self.words("w", every: 0.4, until: 14)
        let r = EchoFilter.run(micCurve: mic, sysCurve: sys, mic: Self.echoed(sw, shift: 0.03), sys: sw)
        XCTAssertEqual(r.droppedSys, 0)
        XCTAssertEqual(r.mic.count, 0)
    }

    func testUnrelatedCurvesDropNothing() {
        for seed in UInt64(10)..<UInt64(15) {
            let mic = Self.speechCurve(frames: 6000, seed: seed)
            let sys = Self.speechCurve(frames: 6000, seed: seed + 100)
            let mw = Self.words("m", every: 0.4, until: 59), sw = Self.words("s", every: 0.4, until: 59, shift: 0.1)
            let r = EchoFilter.run(micCurve: mic, sysCurve: sys, mic: mw, sys: sw)
            XCTAssertEqual(r.droppedMic + r.droppedSys, 0, "seed \(seed)")
            XCTAssertEqual(r.confirmedWindows, 0, "seed \(seed)")
        }
    }

    func testScatteredSingleMatchesDoNotCount() {
        func m(_ w: Int, _ lag: Int) -> EchoFilter.Match { EchoFilter.Match(window: w, lagFrames: lag, score: 0.9) }
        let scattered: [EchoFilter.Match?] = [m(0, 30), nil, m(2, 10), nil, m(4, 45), m(5, 20), m(6, -40)]
        XCTAssertTrue(EchoFilter.decide(scattered).allSatisfy { $0.kind == .fallback })

        let agreeing: [EchoFilter.Match?] = [nil, m(1, 30), m(2, 34), nil]
        let d = EchoFilter.decide(agreeing)
        XCTAssertEqual(d.map(\.kind), [.fallback, .confirmed, .confirmed, .fallback])
        XCTAssertEqual(d[1].echo, .system)
        // Memory: the unmatched window after a confirmed system echo falls back to system.
        XCTAssertEqual(d[3].echo, .system)
        XCTAssertEqual(d[0].echo, .mic)
    }

    func testFallbackMemoryLastsThreeWindows() {
        func m(_ w: Int, _ lag: Int) -> EchoFilter.Match { EchoFilter.Match(window: w, lagFrames: lag, score: 0.9) }
        let d = EchoFilter.decide([m(0, 30), m(1, 30), nil, nil, nil, nil])
        XCTAssertEqual(d.map(\.echo), [.system, .system, .system, .system, .system, .mic])
    }

    func testFallbackDropsOnlyTwinWords() {
        let decisions = [EchoFilter.Decision(window: 0, kind: .fallback, echo: .mic, lag: 0)]
        let mic = [Word(text: "Hello,", start: 0.1, end: 0.3), Word(text: "really", start: 0.5, end: 0.7)]
        let sys = [Word(text: "hello", start: 0.05, end: 0.25)]
        let r = EchoFilter.filter(mic: mic, sys: sys, decisions: decisions)
        XCTAssertEqual(r.mic.map(\.text), ["really"])
        XCTAssertEqual(r.sys.count, 1)
    }

    func testIncrementalMatchesEqualBatch() {
        let mic = Self.speechCurve(frames: 1500, seed: 3)
        let sys = Array(delayed(mic, frames: 25, gain: -3).prefix(1500))
        let all = EchoFilter.matches(mic: mic, sys: sys, windows: 0..<10)
        let parts = EchoFilter.matches(mic: mic, sys: sys, windows: 0..<4) + EchoFilter.matches(mic: mic, sys: sys, windows: 4..<10)
        XCTAssertEqual(all, parts)
        XCTAssertEqual(all.compactMap { $0?.lagFrames }.filter { abs($0 - 25) <= 1 }.count, all.compactMap { $0 }.count)
    }

    /// Live path: audio arrives 100 ms at a time; a 0.3 s, -6 dB copy of the mic on the system stream
    /// (room-on-call) must lose its words as windows are released, while the mic keeps all of its own.
    func testLiveTrackerDropsDelayedSystemCopy() {
        let mic = Self.speechCurve(frames: 3000, seed: 1)
        let sys = Array(delayed(mic, frames: 30, gain: -6).prefix(3000))
        let mw = Self.words("w", every: 0.4, until: 29)
        let sw = Self.echoed(mw, shift: 0.3)
        func slice(_ c: [Float], _ from: Double, _ to: Double, end: Double) -> [Float] {
            let a = Int((from * 100).rounded()), b = Int((to * 100).rounded()), have = Int((end * 100).rounded())
            return (a..<b).map { $0 < min(have, c.count) ? c[$0] : Loudness.floorDBFS }
        }
        var tracker = LiveEchoTracker()
        var t = 0.0
        var midway: (mic: [Word], sys: [Word])?
        while t < 30 {
            t += 0.1
            let end = t
            tracker.advance(micAudioEnd: end, systemAudioEnd: end) { kind, from, to in
                slice(kind == .mic ? mic : sys, from, to, end: end)
            }
            if midway == nil, t >= 15 { midway = tracker.filter(mic: mw.filter { $0.end <= 15 }, sys: sw.filter { $0.end <= 15 }) }
        }
        let out = tracker.filter(mic: mw, sys: sw)
        XCTAssertEqual(out.mic.count, mw.count, "dropped mic \(Set(mw.map(\.text)).subtracting(out.mic.map(\.text)))")
        // Words in the last 2.5 s are not judged yet (the window needs 1 s of audio past its end).
        XCTAssertEqual(out.sys.filter { $0.end < 27 }.map(\.text), [])
        XCTAssertEqual(midway?.mic.count, mw.filter { $0.end <= 15 }.count)
        XCTAssertTrue(midway?.sys.filter { $0.end < 12 }.isEmpty ?? false, "kept \(midway?.sys.map(\.text) ?? [])")
        XCTAssertGreaterThan(tracker.decisions.filter { $0.kind == .confirmed }.count, 15)
    }
}
