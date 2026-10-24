import Foundation

/// Per-meeting exclusion between the pipeline and recordings conversion (Settings "Encrypt
/// recordings"), both of which rewrite `meeting.json` and the audio files. The pipeline waits for
/// the lock; conversion only tries it and skips a meeting the pipeline holds.
public final class MeetingLock: @unchecked Sendable {
    public static let shared = MeetingLock()
    private let lock = NSLock()
    private var held: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    /// Takes the lock for `id` if it is free.
    public func tryAcquire(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return held.insert(id).inserted
    }

    /// Waits until `id` is free, then takes it. Waiters are served in order.
    public func acquire(_ id: String) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if held.insert(id).inserted { lock.unlock(); c.resume(); return }
            waiters[id, default: []].append(c)
            lock.unlock()
        }
    }

    /// Hands `id` to the next waiter, or frees it.
    public func release(_ id: String) {
        lock.lock()
        if var q = waiters[id], !q.isEmpty {
            let next = q.removeFirst()
            waiters[id] = q.isEmpty ? nil : q
            lock.unlock()
            next.resume()  // still held, now by the waiter
            return
        }
        held.remove(id)
        lock.unlock()
    }

    public func isHeld(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return held.contains(id)
    }
}
