import Foundation
import HearsayCore
import UserNotifications

/// Local notifications. UNUserNotificationCenter crashes outside an app bundle, so a bare
/// `swift run` binary only logs.
enum Notifier {
    private static let log = HSLog("notify")
    private static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            log.info("Notification permission \(granted ? "granted" : "not granted")\(error.map { ": \($0)" } ?? "")")
        }
    }

    static func post(id: String, title: String, body: String) {
        log.info("Notify \(id): \(title) - \(body)")
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    static func remove(id: String) {
        guard available else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }
}
