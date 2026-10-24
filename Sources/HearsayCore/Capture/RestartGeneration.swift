import Foundation

/// A restart chain (device change, call-app pause, silent-mic retry) takes a token; a newer `begin()`
/// or a `cancel()` invalidates older tokens, so a stale chain stops at its next check instead of
/// rebuilding over a newer one or over `stop()`.
public final class RestartGeneration: @unchecked Sendable {
    public struct Token: Sendable, Equatable { public let value: UInt64 }

    private let lock = NSLock()
    private var current: UInt64 = 0

    public init() {}

    public func begin() -> Token {
        lock.lock(); defer { lock.unlock() }
        current &+= 1
        return Token(value: current)
    }

    /// Invalidates every outstanding token.
    public func cancel() { _ = begin() }

    public func isCurrent(_ token: Token) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token.value == current
    }
}
