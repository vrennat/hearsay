import AppKit
import Foundation
import HearsayCore
import Sparkle

/// Self-update through Sparkle. The feed is the latest GitHub release's `appcast.xml` (`SUFeedURL`, written by `scripts/build-app.sh`), each update is checked against
/// `SUPublicEDKey`, and Sparkle checks once a day after asking the first time.
@MainActor
enum Updater {
    private static let log = HSLog("update")
    private static var controller: SPUStandardUpdaterController?

    /// Whether this build can update itself: inside a `.app`, with a key and a feed.
    static var available: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return Bundle.main.bundlePath.hasSuffix(".app")
            && (info["SUPublicEDKey"] as? String)?.isEmpty == false && info["SUFeedURL"] != nil
    }

    /// At launch (never for previews or test instances).
    static func start() {
        guard available, controller == nil else {
            if !available { log.info("Updates off: not a signed Developer ID build with a feed and key") }
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        log.info("Updates on: \(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") ?? "")")
    }

    /// Sparkle's own daily check, stored by Sparkle in this app's defaults (`SUEnableAutomaticChecks`).
    /// Off: nothing is checked until you choose Check for Updates.
    static var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            log.info("Automatic update checks \(newValue ? "on" : "off")")
        }
    }

    /// Whether Sparkle is running in this process (the toggle needs it).
    static var isRunning: Bool { controller != nil }

    static func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}
