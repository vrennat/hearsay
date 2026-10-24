import Foundation
import HearsayCore
import Observation

/// Processes recorded meetings one at a time, in order, through `ProcessPipeline.process`.
@MainActor @Observable
final class ProcessingQueue {
    private let log = HSLog("queue")
    /// Swapped by `AppModel` only while idle (Meetings folder change).
    var store: MeetingStore
    private(set) var pending: [String] = [] { didSet { onChange?() } }
    private(set) var current: String? { didSet { onChange?() } }
    /// Any change to `pending` or `current` (AppModel mirrors the busy set for retention).
    var onChange: (() -> Void)?
    private var worker: Task<Void, Never>?
    var onFinished: ((String) -> Void)?

    init(store: MeetingStore) { self.store = store }

    /// Ids queued or being processed; retention must skip them.
    var busy: Set<String> { Set(pending + (current.map { [$0] } ?? [])) }
    var isIdle: Bool { current == nil && pending.isEmpty }

    func enqueue(_ id: String) {
        guard !busy.contains(id) else { return }
        pending.append(id)
        log.info("Queued \(id)")
        if worker == nil { worker = Task { await drain() } }
    }

    private func drain() async {
        while !pending.isEmpty {
            let id = pending.removeFirst()
            current = id
            do {
                try await ProcessPipeline.process(meetingID: id, store: store,
                                                  options: ProcessOptions(cleanup: Prefs.cleanupOn, userName: Prefs.userNameValue,
                                                                         encryptAudio: Prefs.encryptRecordingsOn))
            } catch CryptoError.transcriptsLocked {
                // Left `recorded`; AppModel re-queues it once the password is entered.
                log.info("Processing \(id) waits for the transcript password")
            } catch {
                log.error("Processing \(id) failed: \(error)")
                if var m = try? store.loadMeeting(id) {
                    m.status = .failed
                    m.error = String(describing: error)
                    try? store.saveMeeting(m)
                }
            }
            current = nil
            onFinished?(id)
        }
        worker = nil
    }

    func waitUntilIdle() async {
        while !isIdle { try? await Task.sleep(for: .milliseconds(100)) }
    }
}
