import Foundation
import HearsayCore

/// Settings keys and the defaults domain `com.tannervass.hearsay` (the CLI reads the same suite).
/// Inside the bundle that domain is `.standard`: passing the app's own bundle id as a suite name is
/// rejected by Foundation with a console warning.
enum Prefs {
    static let suite = "com.tannervass.hearsay"
    static let defaults: UserDefaults =
        Bundle.main.bundleIdentifier == suite ? .standard : (UserDefaults(suiteName: suite) ?? .standard)

    static let cleanup = "cleanup"
    static let notchPill = "notchPill"
    static let userName = "userName"
    static let keepAudioDays = "keepAudioDays"
    static let keepTranscriptDays = "keepTranscriptDays"
    static let dictation = "dictation"
    static let dictationKey = "dictationKey"
    static let encryptRecordings = "encryptRecordings"
    /// "menu" (default, a standard NSMenu) or "panel" (the rich window panel); read once at launch.
    static let menuStyle = "menuStyle"

    static var encryptRecordingsOn: Bool { defaults.object(forKey: encryptRecordings) as? Bool ?? true }

    /// Audio and transcripts are kept forever (0) unless the user picks a limit: an earlier
    /// "Until transcribed" default deleted the audio of every existing meeting at first launch. `integer(forKey:)` would read an unset key
    /// as 0 = forever, so every reader goes through these.
    static let defaultKeepAudioDays = 0
    static let defaultKeepTranscriptDays = 0
    static var keepAudioDaysValue: Int { defaults.object(forKey: keepAudioDays) as? Int ?? defaultKeepAudioDays }
    static var keepTranscriptDaysValue: Int { defaults.object(forKey: keepTranscriptDays) as? Int ?? defaultKeepTranscriptDays }
    static var notchPillOn: Bool { defaults.object(forKey: notchPill) as? Bool ?? true }

    static var cleanupOn: Bool { defaults.object(forKey: cleanup) as? Bool ?? true }
    static var dictationOn: Bool { defaults.bool(forKey: dictation) }

    /// Your name for the voiceprint and 1:1 rules when the calendar gave no `me`; nil when unset.
    static var userNameValue: String? {
        let n = defaults.string(forKey: userName)?.trimmingCharacters(in: .whitespaces) ?? ""
        return n.isEmpty ? nil : n
    }
}

/// Which build this is: the Info.plist key `HSDistribution` written by `scripts/build-app.sh`
/// (`appStore` with `--mas`, else `developerID`). A bare `swift run` binary reads as Developer ID.
enum Distribution: String {
    case developerID, appStore

    static let current: Distribution =
        (Bundle.main.object(forInfoDictionaryKey: "HSDistribution") as? String).flatMap(Distribution.init) ?? .developerID

    /// The clamshell override is a private IOPMrootDomain call; the store build keeps only the
    /// idle-sleep assertion.
    var allowsClamshellOverride: Bool { self == .developerID }
}
