import Foundation

/// The dictation hotkey rules (spec, Dictation), pure so they can be tested without event taps.
///
/// - Press the key: start listening.
/// - Release after 0.3 s or more: finish (paste). Any other key while holding: cancel.
/// - Release under 0.3 s: latch. Listen until the next press of the key, which finishes; other keys
///   do not cancel, Esc does. The release that follows the finishing press is swallowed.
public struct DictationKeyMachine: Sendable, Equatable {
    public static let latchSeconds = 0.3

    public enum Event: Sendable, Equatable {
        /// The dictation key went down / up (from `flagsChanged`).
        case keyDown(at: Double)
        case keyUp(at: Double)
        /// Any other key or modifier pressed; `escape` for Esc.
        case otherKey(escape: Bool)
    }

    public enum Action: Sendable, Equatable { case none, start, finish, cancel }

    public enum State: Sendable, Equatable {
        case idle
        case holding(since: Double)
        case latched
        /// Finished or cancelled while the key is still down; its release is ignored.
        case waitingForRelease
    }

    public private(set) var state: State = .idle

    public init() {}

    public mutating func handle(_ event: Event) -> Action {
        switch (state, event) {
        case (.idle, .keyDown(let t)):
            state = .holding(since: t)
            return .start
        case (.holding(let since), .keyUp(let t)):
            if t - since < Self.latchSeconds {
                state = .latched
                return .none
            }
            state = .idle
            return .finish
        case (.holding, .otherKey):
            state = .waitingForRelease
            return .cancel
        case (.latched, .keyDown):
            state = .waitingForRelease
            return .finish
        case (.latched, .otherKey(let escape)):
            guard escape else { return .none }
            state = .idle
            return .cancel
        case (.waitingForRelease, .keyUp):
            state = .idle
            return .none
        default:
            return .none
        }
    }

    /// Back to idle without an action (dictation turned off, monitors removed).
    public mutating func reset() { state = .idle }
}
