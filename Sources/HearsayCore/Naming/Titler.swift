import Foundation

/// Spec step 8: the calendar title when there is one, else a date-time name.
public enum Titler {
    /// Titles that mean "nothing chosen yet" (lowercased).
    public static let placeholders: Set<String> = ["", "meeting", "new meeting", "untitled", "recording", "untitled meeting"]

    public static func isPlaceholder(_ title: String) -> Bool {
        placeholders.contains(title.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// `yyyy-MM-dd HH:mm Meeting` in local time.
    public static func dateTimeTitle(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(f.string(from: date)) Meeting"
    }

    public static func title(for meeting: Meeting, timeZone: TimeZone = .current) -> String {
        isPlaceholder(meeting.title) ? dateTimeTitle(meeting.startedAt, timeZone: timeZone) : meeting.title
    }
}
