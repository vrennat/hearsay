import Foundation
import Testing
@testable import HearsayCore

@Suite struct MeetingListTests {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.locale = Locale(identifier: "en_US")
        return c
    }

    func meeting(_ id: String, _ iso: String, title: String = "", attendees: [String] = [],
                 names: [String: String] = [:]) -> Meeting {
        Meeting(id: id, title: title, startedAt: ISO8601DateFormatter().date(from: iso)!,
                status: .done, speakerNames: names, attendees: attendees)
    }

    @Test func groupsByLocalDayNewestFirstWithRecordingOnTop() {
        let now = ISO8601DateFormatter().date(from: "2026-10-23T15:00:00Z")!  // 10:00 in Chicago
        let ms = [
            meeting("a", "2026-10-23T14:00:00Z"),
            meeting("b", "2026-10-23T03:00:00Z"),  // 22:00 on the 22nd in Chicago
            meeting("c", "2026-10-20T16:00:00Z"),
            meeting("rec", "2026-10-23T14:30:00Z"),
            meeting("d", "2025-12-31T16:00:00Z"),
        ]
        let g = MeetingList.groups(ms, recordingID: "rec", now: now, calendar: cal)
        #expect(g.map(\.title) == ["Recording", "Today", "Yesterday", "Tuesday, October 20", "Wednesday, December 31, 2025"])
        #expect(g.map { $0.meetings.map(\.id) } == [["rec"], ["a"], ["b"], ["c"], ["d"]])
        #expect(MeetingList.groups(ms, recordingID: nil, now: now, calendar: cal)[0].meetings.map(\.id) == ["rec", "a"])
    }

    @Test func filterMatchesEveryWordAcrossFields() {
        let ms = [
            meeting("1", "2026-10-23T14:00:00Z", title: "Weekly design sync", attendees: ["Renée Park"]),
            meeting("2", "2026-10-23T15:00:00Z", title: "Budget", names: ["S1": "Omar"]),
        ]
        #expect(MeetingList.filter(ms, query: "  ").count == 2)
        #expect(MeetingList.filter(ms, query: "DESIGN renee").map(\.id) == ["1"])
        #expect(MeetingList.filter(ms, query: "omar").map(\.id) == ["2"])
        #expect(MeetingList.filter(ms, query: "design omar").isEmpty)
    }
}
