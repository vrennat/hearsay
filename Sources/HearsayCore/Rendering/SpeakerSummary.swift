import Foundation

/// A speaker as rendered: label, typed name, talk time, and whether it counts as a main voice.
public struct SpeakerSummary: Sendable, Equatable, Codable {
    public let id: String
    public let name: String?
    public let label: String
    public let talkSeconds: Double
    public let main: Bool

    public var displayName: String { name ?? label }

    /// Voices under this share of their stream's talk time are not main speakers.
    public static let mainShare = 0.05

    public static func summarize(_ transcript: Transcript, names: [String: String]) -> [SpeakerSummary] {
        var perStream: [StreamKind: Double] = [:]
        for s in transcript.speakers { perStream[s.stream, default: 0] += s.talkSeconds }
        return transcript.speakers.map { s in
            let total = perStream[s.stream] ?? 0
            let name = names[s.id].flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            return SpeakerSummary(
                id: s.id, name: name, label: s.defaultLabel, talkSeconds: s.talkSeconds,
                main: total <= 0 || s.talkSeconds / total >= mainShare)
        }
    }

    /// True when every main speaker has a name (and there is at least one).
    public static func allNamed(_ speakers: [SpeakerSummary]) -> Bool {
        let main = speakers.filter(\.main)
        return !main.isEmpty && main.allSatisfy { $0.name != nil }
    }
}
