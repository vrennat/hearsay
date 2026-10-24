import Foundation

/// The main window's sidebar as pure data: a search filter and day grouping over loaded meetings.
public enum MeetingList {
    public struct Group: Identifiable, Equatable, Sendable {
        /// "recording", or the day as `yyyy-MM-dd` in the calendar's time zone.
        public let id: String
        public let title: String
        public let meetings: [Meeting]
    }

    /// Meetings whose title, id, attendees or speaker names contain every whitespace-separated word
    /// of `query` (case- and diacritic-insensitive). An empty query keeps everything.
    public static func filter(_ meetings: [Meeting], query: String) -> [Meeting] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return meetings }
        return meetings.filter { m in
            let fields = [m.title, m.id] + m.attendees + Array(m.speakerNames.values)
            return words.allSatisfy { w in
                fields.contains { $0.range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
    }

    /// Newest first. The meeting being recorded (`recordingID`) goes alone in a leading "Recording"
    /// group; the rest are grouped by start day: "Today", "Yesterday", then the date.
    public static func groups(_ meetings: [Meeting], recordingID: String?, now: Date = Date(),
                              calendar: Calendar = .current) -> [Group] {
        let sorted = meetings.sorted { $0.startedAt > $1.startedAt }
        var out: [Group] = []
        let live = sorted.filter { $0.id == recordingID }
        if !live.isEmpty { out.append(Group(id: "recording", title: "Recording", meetings: live)) }
        let key = DateFormatter()
        key.calendar = calendar
        key.timeZone = calendar.timeZone
        key.locale = Locale(identifier: "en_US_POSIX")
        key.dateFormat = "yyyy-MM-dd"
        var order: [String] = []
        var byDay: [String: [Meeting]] = [:]
        var dayStart: [String: Date] = [:]
        for m in sorted where m.id != recordingID {
            let k = key.string(from: m.startedAt)
            if byDay[k] == nil { order.append(k); dayStart[k] = calendar.startOfDay(for: m.startedAt) }
            byDay[k, default: []].append(m)
        }
        for k in order {
            out.append(Group(id: k, title: dayTitle(dayStart[k]!, now: now, calendar: calendar), meetings: byDay[k]!))
        }
        return out
    }

    static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) { return "Yesterday" }
        var style = Date.FormatStyle(date: .complete, time: .omitted, locale: calendar.locale ?? .current,
                                     calendar: calendar, timeZone: calendar.timeZone)
        if calendar.component(.year, from: day) == calendar.component(.year, from: now) {
            style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
                .weekday(.wide).month(.wide).day()
        }
        return day.formatted(style)
    }
}
