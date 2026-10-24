import Foundation

/// Finds Hearsay crash reports newer than the last check (spec, Crash relaunch). The app posts one
/// notification for the result and then calls `markChecked`.
public enum CrashReports {
    public struct Report: Sendable, Equatable {
        public let url: URL
        public let date: Date
    }

    public static let defaultsSuite = "com.tannervass.hearsay"
    public static let lastCheckKey = "lastCrashReportCheck"

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// `Hearsay-*.ips` files in `directory` modified after `since` (all of them when nil), oldest first.
    public static func list(in directory: URL = defaultDirectory, since: Date?) -> [Report] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { url -> Report? in
            let name = url.lastPathComponent
            guard name.hasPrefix("Hearsay-"), url.pathExtension == "ips" else { return nil }
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return nil }
            if let since, date <= since { return nil }
            return Report(url: url, date: date)
        }.sorted { $0.date < $1.date }
    }

    public static func lastCheck(_ defaults: UserDefaults? = UserDefaults(suiteName: defaultsSuite)) -> Date? {
        defaults?.object(forKey: lastCheckKey) as? Date
    }

    public static func markChecked(_ date: Date = Date(), _ defaults: UserDefaults? = UserDefaults(suiteName: defaultsSuite)) {
        defaults?.set(date, forKey: lastCheckKey)
    }

    /// Reports since the saved date. With no saved date, nothing is reported (first launch should not
    /// surface ancient crashes); the caller still marks the check so the next launch has a baseline.
    public static func newSinceLastCheck(
        in directory: URL = defaultDirectory, defaults: UserDefaults? = UserDefaults(suiteName: defaultsSuite)
    ) -> [Report] {
        guard let since = lastCheck(defaults) else { return [] }
        return list(in: directory, since: since)
    }
}
