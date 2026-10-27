import AppKit
import Foundation
import HearsayCore
#if !HEARSAY_NO_SPARKLE
import Sparkle
#endif

/// Self-update through Sparkle, Developer ID build only. The feed is the latest GitHub release's
/// `appcast.xml` (`SUFeedURL`, written by `scripts/build-app.sh`), each update is checked against
/// `SUPublicEDKey`, and Sparkle checks once a day after asking the first time. The App Store build is
/// compiled with `HEARSAY_NO_SPARKLE` and ships without the framework: the store updates it.
@MainActor
enum Updater {
    private static let log = HSLog("update")
    #if !HEARSAY_NO_SPARKLE
    private static var controller: SPUStandardUpdaterController?
    #endif

    /// Whether this build can update itself: Developer ID, inside a `.app`, with a key and a feed.
    static var available: Bool {
        #if HEARSAY_NO_SPARKLE
        return false
        #else
        let info = Bundle.main.infoDictionary ?? [:]
        return Distribution.current == .developerID && Bundle.main.bundlePath.hasSuffix(".app")
            && (info["SUPublicEDKey"] as? String)?.isEmpty == false && info["SUFeedURL"] != nil
        #endif
    }

    /// At launch (never for previews or test instances).
    static func start() {
        #if !HEARSAY_NO_SPARKLE
        guard available, controller == nil else {
            if !available { log.info("Updates off: not a signed Developer ID build with a feed and key") }
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        log.info("Updates on: \(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") ?? "")")
        #endif
    }

    static func checkForUpdates() {
        #if !HEARSAY_NO_SPARKLE
        guard let controller else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
        #endif
    }
}
