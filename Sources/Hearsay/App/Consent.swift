import Foundation

/// The recording-consent reminder, shown wherever a recording can be started or is in progress
/// (menu panel, main and live windows, Settings → Recording). Hearsay cannot know who is in the
/// room or on the call, or which jurisdiction's rules apply, so the duty to tell people stays
/// with the user and the app says so rather than pretending to handle it.
enum Consent {
    static let reminder = "Tell everyone you are recording. Consent laws vary."
    static let detail = "Many places require every participant's consent before a conversation is recorded. Hearsay does not announce itself, so say so before you start."
}
