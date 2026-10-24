import Foundation
import XCTest
@testable import HearsayCore

final class CalendarPickTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    func ev(_ id: String, cal: String = "work", from: Double = -10, to: Double = 20, guests: [String] = [],
            me: Bool = false, response: CalendarPick.Response = .unanswered, allDay: Bool = false) -> CalendarPick.Event {
        CalendarPick.Event(id: id, calendarID: cal, title: id, start: at(from), end: at(to), isAllDay: allDay,
                           attendees: guests, includesMe: me, myResponse: response)
    }

    func testOwnEventWithoutGuestsCounts() {
        XCTAssertEqual(CalendarPick.current(at: now, in: [ev("focus")])?.id, "focus")
    }

    func testNothingInProgress() {
        XCTAssertNil(CalendarPick.current(at: now, in: [ev("later", from: 5, to: 30), ev("done", from: -60, to: 0)]))
    }

    func testGuestListWithoutMeCountsOnlyWhereIAmOnOtherGuestListsWithin6h() {
        // Own calendar: the event lists only the other person, but I'm a guest elsewhere on it today.
        let oneOnOne = ev("1:1 Rob", cal: "mine", guests: ["Rob"])
        let standup = ev("standup", cal: "mine", from: -180, to: -165, guests: ["Me", "Ann"], me: true, response: .accepted)
        XCTAssertEqual(CalendarPick.current(at: now, in: [oneOnOne, standup])?.id, "1:1 Rob")

        // Shared interview calendar: I'm on no guest list there.
        let interview = ev("interview", cal: "shared", guests: ["Candidate", "Bob"])
        XCTAssertNil(CalendarPick.current(at: now, in: [interview]))
        XCTAssertNil(CalendarPick.current(at: now, in: [interview, standup]), "my guest lists on another calendar do not count")

        // Too far away: 7 h before.
        let old = ev("old", cal: "shared", from: -420, to: -400, guests: ["Me"], me: true)
        XCTAssertNil(CalendarPick.current(at: now, in: [interview, old]))
        let near = ev("near", cal: "shared", from: -350, to: -340, guests: ["Me"], me: true)
        XCTAssertEqual(CalendarPick.current(at: now, in: [interview, near])?.id, "interview")
    }

    func testAcceptedBeatsUnansweredOnTie() {
        let a = ev("pending", guests: ["Me", "X"], me: true, response: .unanswered)
        let b = ev("accepted", from: -20, guests: ["Me", "Y"], me: true, response: .accepted)
        XCTAssertEqual(CalendarPick.current(at: now, in: [a, b])?.id, "accepted")
        XCTAssertEqual(CalendarPick.current(at: now, in: [b, a])?.id, "accepted")
    }

    func testDeclinedAndAllDayNeverCount() {
        XCTAssertNil(CalendarPick.current(at: now, in: [ev("no", guests: ["Me"], me: true, response: .declined),
                                                        ev("holiday", from: -600, to: 600, allDay: true)]))
    }

    func testLatestStartWinsAmongEquals() {
        XCTAssertEqual(CalendarPick.current(at: now, in: [ev("early", from: -50), ev("late", from: -5)])?.id, "late")
    }
}
