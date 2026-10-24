import Foundation
import HearsayCore
@preconcurrency import UserNotifications

/// The one `UNUserNotificationCenter` delegate. Shows banners while the accessory app is frontmost and
/// routes actions by category id to handlers other features register (`register`), so each feature
/// keeps its own category without clashing. Categories are merged into the existing set, never
/// replaced. The mic-silence warning (`mic-silent`) has no category and no actions.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationRouter()
    typealias Handler = @MainActor (_ actionID: String, _ request: UNNotificationRequest) -> Void

    private let log = HSLog("notify")
    private var handlers: [String: Handler] = [:]
    private var installed = false

    static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    @MainActor
    func install() {
        guard Self.available, !installed else { return }
        installed = true
        UNUserNotificationCenter.current().delegate = self
    }

    /// Adds `category` to the centre's set and routes its actions (and a tap on the banner) to `handler`.
    @MainActor
    func register(_ category: UNNotificationCategory, handler: @escaping Handler) {
        handlers[category.identifier] = handler
        guard Self.available else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            var set = existing.filter { $0.identifier != category.identifier }
            set.insert(category)
            center.setNotificationCategories(set)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        let category = request.content.categoryIdentifier
        let action = response.actionIdentifier
        log.info("Notification action \(action) on \(request.identifier) (\(category))")
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.handlers[category]?(action, request) }
            completionHandler()
        }
    }
}
