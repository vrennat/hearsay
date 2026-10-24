import AppKit
import Foundation
import HearsayCore
@preconcurrency import UserNotifications

/// Launch-time checks that post a notification. Not run for test instances (they share the defaults).
@MainActor
enum LaunchChecks {
    private static let log = HSLog("launch")
    static let crashCategory = "crash-report"
    static let revealAction = "reveal"

    /// One notification for `Hearsay-*.ips` reports newer than the saved check date, then saves now.
    /// With no saved date (first launch) nothing is reported.
    static func postCrashReports() {
        let reports = CrashReports.newSinceLastCheck(defaults: Prefs.defaults)
        CrashReports.markChecked(Date(), Prefs.defaults)
        log.info("Crash reports since last check: \(reports.count)")
        guard let newest = reports.last else { return }

        NotificationRouter.shared.register(UNNotificationCategory(
            identifier: crashCategory,
            actions: [UNNotificationAction(identifier: revealAction, title: "Show Report")],
            intentIdentifiers: [])) { action, request in
            guard action == revealAction || action == UNNotificationDefaultActionIdentifier,
                  let path = request.content.userInfo["path"] as? String else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        guard NotificationRouter.available else { return }
        let content = UNMutableNotificationContent()
        content.title = "Hearsay quit unexpectedly"
        content.body = reports.count == 1
            ? "A crash report was written at \(newest.date.formatted(date: .abbreviated, time: .shortened))."
            : "\(reports.count) crash reports since the last launch; the newest is from \(newest.date.formatted(date: .abbreviated, time: .shortened))."
        content.categoryIdentifier = crashCategory
        content.userInfo = ["path": newest.url.path]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: crashCategory, content: content, trigger: nil))
    }
}
