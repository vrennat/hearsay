import Foundation

/// Which calendar event a recording belongs to (spec, Calendar). Pure, over plain values, so the app's
/// EventKit adapter stays thin and the rule is unit-tested.
///
/// - An event with a guest list you are not on counts only on a calendar where you are on some other
///   event's guest list within 6 hours of it. This keeps your own calendar's events that list only the
///   other person and drops shared calendars (interview schedules and the like).
/// - Declined events and all-day events never count.
/// - On a tie, accepted beats unanswered; then the latest start (the meeting you just joined), then the
///   shortest event.
public enum CalendarPick {
    public enum Response: Sendable, Equatable { case accepted, unanswered, tentative, declined }

    public struct Event: Sendable, Equatable {
        public var id: String
        public var calendarID: String
        public var title: String
        public var start: Date
        public var end: Date
        public var isAllDay: Bool
        /// Guest list, possibly empty.
        public var attendees: [String]
        /// You are on the guest list (EventKit `isCurrentUser`).
        public var includesMe: Bool
        /// Your response; `unanswered` when you are not a guest (your own event).
        public var myResponse: Response
        /// Your name as the guest list has it.
        public var me: String?

        public init(id: String, calendarID: String, title: String, start: Date, end: Date, isAllDay: Bool = false,
                    attendees: [String] = [], includesMe: Bool = false, myResponse: Response = .unanswered, me: String? = nil) {
            self.id = id; self.calendarID = calendarID; self.title = title; self.start = start; self.end = end
            self.isAllDay = isAllDay; self.attendees = attendees; self.includesMe = includesMe
            self.myResponse = myResponse; self.me = me
        }
    }

    public static let neighbourWindow: TimeInterval = 6 * 3600

    /// The event in progress at `now` among `events` (pass every event within 6 h of now, on every calendar).
    public static func current(at now: Date, in events: [Event]) -> Event? {
        let live = events.filter { !$0.isAllDay && $0.start <= now && now < $0.end && $0.myResponse != .declined }
        let counted = live.filter { counts($0, among: events) }
        return counted.min { a, b in
            if rank(a.myResponse) != rank(b.myResponse) { return rank(a.myResponse) < rank(b.myResponse) }
            if a.start != b.start { return a.start > b.start }
            return a.end.timeIntervalSince(a.start) < b.end.timeIntervalSince(b.start)
        }
    }

    static func counts(_ e: Event, among events: [Event]) -> Bool {
        guard !e.attendees.isEmpty, !e.includesMe else { return true }
        return events.contains { o in
            o.id != e.id && o.calendarID == e.calendarID && o.includesMe
                && abs(o.start.timeIntervalSince(e.start)) <= neighbourWindow
        }
    }

    private static func rank(_ r: Response) -> Int {
        switch r { case .accepted: 0; case .tentative: 1; case .unanswered: 2; case .declined: 3 }
    }
}
