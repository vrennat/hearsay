import Foundation
import HearsayCore
import Observation

/// What the Live window shows: the live lines (refreshed at each `live.json` save, every 2 s), the live
/// speakers with their typed names, and name hints (suggestions only, never applied).
@MainActor @Observable
final class LiveModel {
    static let shared = LiveModel()

    struct Speaker: Identifiable, Equatable {
        let id: String
        let stream: StreamKind
        var talkSeconds: Double
    }

    private let log = HSLog("live-ui")
    private(set) var meetingID: String?
    private(set) var lines: [LiveLine] = []
    private(set) var speakers: [Speaker] = []
    private(set) var names: [String: String] = [:]
    private(set) var hints: [String: NameHints.Hint] = [:]
    private(set) var isRecording = false
    private var candidates: Set<String> = []

    func begin(meeting: Meeting, store: MeetingStore) {
        meetingID = meeting.id
        lines = []; speakers = []; names = [:]; hints = [:]
        isRecording = true
        // Attendees plus every name typed in any meeting; computed once (it reads every folder).
        candidates = NameHints.candidates(for: meeting, store: store)
    }

    func end() { isRecording = false }

    func update(_ new: [LiveLine]) {
        lines = new
        var talk: [String: (StreamKind, Double)] = [:]
        for l in new { talk[l.speaker, default: (l.stream, 0)].1 += max(0, l.end - l.start) }
        speakers = talk.map { Speaker(id: $0.key, stream: $0.value.0, talkSeconds: $0.value.1) }
            .sorted { $0.stream != $1.stream ? $0.stream == .mic : Self.slot($0.id) < Self.slot($1.id) }
        let pool = candidates.union(NameHints.candidates(attendees: [], typedNames: Array(names.values)))
        let utterances = new.map { Utterance(speaker: $0.speaker, stream: $0.stream, start: $0.start, end: $0.end, text: $0.text) }
        hints = Dictionary(NameHints.hints(utterances: utterances, candidates: pool).map { ($0.speaker, $0) },
                           uniquingKeysWith: { a, _ in a })
    }

    func label(_ id: String) -> String { names[id] ?? Self.defaultLabel(id) }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names[id] = trimmed.isEmpty ? nil : trimmed
        let log = self.log
        Task.detached {
            do { try await LiveTranscriber.shared.renameSpeaker(id, to: trimmed) } catch { log.error("Live rename failed: \(error)") }
        }
    }

    static func slot(_ id: String) -> Int { Int(id.split(separator: "-").last ?? "") ?? 0 }

    /// Room N for mic voices, Remote N for call voices (spec default labels; `Me` is only decided after the call).
    static func defaultLabel(_ id: String) -> String {
        (id.hasPrefix("sys") ? "Remote " : "Room ") + String(slot(id))
    }
}
