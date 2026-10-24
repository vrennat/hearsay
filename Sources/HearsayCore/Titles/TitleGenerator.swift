import Foundation
import FoundationModels
import Synchronization

/// Proposes a title from a prompt. `OnDeviceTitleModel` is the real one; tests pass a stub so the
/// fallback, timeout and validation paths run without Apple Intelligence.
public protocol TitleModel: Sendable {
    func propose(prompt: String, instructions: String) async throws -> String
}

public enum TitleModelError: Error, CustomStringConvertible, Equatable {
    case unavailable(String)
    public var description: String {
        switch self { case .unavailable(let r): return "model unavailable: \(r)" }
    }
}

@Generable(description: "A short title for a recorded meeting")
struct GeneratedTitle {
    @Guide(description: "3 to 8 words in Title Case naming the meeting's topic; no date, no quotes, no trailing punctuation, not the word Meeting, not just a person's name")
    var title: String
}

/// FoundationModels `SystemLanguageModel.default`, a fresh `LanguageModelSession` per call and the
/// guided `GeneratedTitle` struct.
public struct OnDeviceTitleModel: TitleModel {
    public init() {}

    /// `String(describing:)` of `SystemLanguageModel.default.availability`, for logs and the CLI.
    public static var availabilityDescription: String { String(describing: SystemLanguageModel.default.availability) }

    public func propose(prompt: String, instructions: String) async throws -> String {
        if let reason = SpeakerSummaries.unavailableReason() { throw TitleModelError.unavailable(reason) }
        let session = LanguageModelSession(model: .default, instructions: instructions)
        let response = try await session.respond(
            to: prompt, generating: GeneratedTitle.self,
            options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 60))
        return response.content.title
    }
}

/// The on-device titler. Never throws: any failure keeps the existing rule (`Titler.title(for:)`).
public enum TitleGenerator {
    public static let timeout: Duration = .seconds(20)
    private static let log = HSLog("titles")
    private static let unavailableLogged = Mutex(false)

    public struct Outcome: Sendable, Equatable {
        public enum Source: String, Sendable { case userEdited, kept, generated, fallback }
        public let title: String
        public let source: Source
        /// Why the model's title was not used (fallback only).
        public let reason: String?
    }

    /// The pipeline's title. A hand-typed title or a specific calendar title is kept as is; otherwise
    /// the model is asked, its answer validated, and anything else falls back to `Titler`.
    public static func title(meeting: Meeting, transcript: Transcript, cleanup: Cleanup?,
                             model: any TitleModel = OnDeviceTitleModel(), timeout: Duration = timeout) async -> Outcome {
        if meeting.titleEditedByUser { return Outcome(title: meeting.title, source: .userEdited, reason: nil) }
        guard TitleRules.needsGeneration(meeting) else { return Outcome(title: Titler.title(for: meeting), source: .kept, reason: nil) }
        let outcome = await suggest(meeting: meeting, transcript: transcript, cleanup: cleanup, model: model, timeout: timeout)
        if outcome.source == .fallback, let reason = outcome.reason { logFallback(meeting.id, reason) }
        else { log.info("\(meeting.id): titled \"\(outcome.title)\"") }
        return outcome
    }

    /// Asks the model whatever the current title is (`hearsay title --suggest`). `.generated` with the
    /// validated title, or `.fallback` with `Titler.title(for:)` and the reason.
    public static func suggest(meeting: Meeting, transcript: Transcript, cleanup: Cleanup?,
                               model: any TitleModel = OnDeviceTitleModel(), timeout: Duration = timeout) async -> Outcome {
        let fallback = Titler.title(for: meeting)
        let prompt = TitleRules.prompt(meeting: meeting, transcript: transcript, cleanup: cleanup)
        let raw: String
        do {
            raw = try await withTimeout(timeout) { try await model.propose(prompt: prompt, instructions: TitleRules.instructions) }
        } catch {
            return Outcome(title: fallback, source: .fallback, reason: String(describing: error))
        }
        switch TitleRules.validate(raw, names: TitleRules.knownNames(meeting)) {
        case .success(let t): return Outcome(title: t, source: .generated, reason: nil)
        case .failure(let r): return Outcome(title: fallback, source: .fallback, reason: "rejected \"\(raw)\": \(r)")
        }
    }

    /// Unavailability is the same for every meeting, so it is logged once per process.
    static func logFallback(_ id: String, _ reason: String) {
        if reason.hasPrefix("model unavailable") {
            let first = unavailableLogged.withLock { done in defer { done = true }; return !done }
            if first { log.info("titles: \(reason); keeping the calendar or date-time title") }
            return
        }
        log.info("\(id): model title not used (\(reason)); keeping the existing title")
    }

    public struct TimedOut: Error, CustomStringConvertible {
        public let after: Duration
        public var description: String { "no answer within \(after)" }
    }

    /// The first of `work` and a timer. The work task is cancelled on timeout and not awaited, so a call
    /// that ignores cancellation cannot hold up the pipeline.
    static func withTimeout<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let once = Mutex<CheckedContinuation<T, Error>?>(nil)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            once.withLock { $0 = c }
            let task = Task { try await work() }
            let timer = Task {
                try? await Task.sleep(for: limit)
                if let c = once.withLock({ $0.take() }) {
                    task.cancel()
                    c.resume(throwing: TimedOut(after: limit))
                }
            }
            Task {
                let r = await task.result
                timer.cancel()
                once.withLock { $0.take() }?.resume(with: r)
            }
        }
    }
}
