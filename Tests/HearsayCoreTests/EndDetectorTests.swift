import XCTest
@testable import HearsayCore

final class EndDetectorTests: XCTestCase {
    /// Keeps both streams loud every second over [from, to) so only the rule under test can fire.
    func busy(_ d: inout EndDetector, _ from: Double, _ to: Double, mic: Bool = true, system: Bool = true) -> [EndDetector.Prompt] {
        var out: [EndDetector.Prompt] = []
        var t = from
        while t < to {
            if mic, let p = d.handle(.micLoud(t)) { out.append(p) }
            if system, let p = d.handle(.systemLoud(t)) { out.append(p) }
            t += 1
        }
        return out
    }

    func testCallEndedAfter15sAndIgnoresRoomTalk() {
        var d = EndDetector()
        XCTAssertNil(d.handle(.callAppAudio(present: true, at: 0)))
        XCTAssertTrue(busy(&d, 0, 100).isEmpty)
        XCTAssertNil(d.handle(.callAppAudio(present: false, at: 100)))
        // Room talk keeps going; the call-ended check ignores it.
        XCTAssertTrue(busy(&d, 100, 115, system: false).isEmpty)
        XCTAssertNil(d.handle(.tick(114.9)))
        XCTAssertEqual(d.handle(.micLoud(115)), .init(reason: .callEnded, at: 115))
    }

    func testCallAppSilenceWithoutPriorAudioDoesNotFire() {
        var d = EndDetector()
        XCTAssertNil(d.handle(.callAppAudio(present: false, at: 0)))
        XCTAssertTrue(busy(&d, 0, 60).isEmpty)
    }

    func testCallAudioReturningResetsTheCountdown() {
        var d = EndDetector()
        _ = d.handle(.callAppAudio(present: true, at: 0))
        _ = d.handle(.callAppAudio(present: false, at: 10))
        _ = d.handle(.callAppAudio(present: true, at: 20))
        XCTAssertTrue(busy(&d, 20, 40).isEmpty)
    }

    func testCalendarEndedNeedsTwoMinutesAndBothQuiet60s() {
        var d = EndDetector()
        _ = d.handle(.calendarEnd(100))
        XCTAssertTrue(busy(&d, 0, 200).isEmpty)  // last loud at 199, past the 220 s grace
        XCTAssertNil(d.handle(.tick(258.9)))
        XCTAssertEqual(d.handle(.tick(259)), .init(reason: .calendarEnded, at: 259))
    }

    func testCalendarRuleWaitsForGraceEvenWhenQuiet() {
        var d = EndDetector()
        XCTAssertTrue(busy(&d, 0, 10).isEmpty)  // quiet from 9
        _ = d.handle(.calendarEnd(60))
        XCTAssertNil(d.handle(.tick(179.9)))
        XCTAssertEqual(d.handle(.tick(180)), .init(reason: .calendarEnded, at: 180))
    }

    func testRoomTalkBlocksCalendarPrompt() {
        var d = EndDetector()
        _ = d.handle(.calendarEnd(0))
        XCTAssertTrue(busy(&d, 0, 400, system: false).isEmpty)
    }

    func testSilenceAfterFiveMinutes() {
        var d = EndDetector()
        XCTAssertTrue(busy(&d, 0, 11).isEmpty)  // last loud at 10
        XCTAssertNil(d.handle(.tick(309.9)))
        XCTAssertEqual(d.handle(.tick(310)), .init(reason: .silence, at: 310))
    }

    func testSilenceCountsFromStartWithNoAudio() {
        var d = EndDetector(start: 0)
        XCTAssertNil(d.handle(.tick(299)))
        XCTAssertEqual(d.handle(.tick(300))?.reason, .silence)
    }

    func testHoldoff15Minutes() {
        var d = EndDetector()
        XCTAssertEqual(d.handle(.tick(300))?.reason, .silence)
        XCTAssertNil(d.handle(.tick(301)))
        XCTAssertNil(d.handle(.tick(1199.9)))
        XCTAssertEqual(d.handle(.tick(1200)), .init(reason: .silence, at: 1200))
    }
}
