import Foundation
import FoundationModels

/// One-line speaker summaries from the on-device model (spec, Naming aids). Not saved; shown as a
/// naming hint only. Biggest talkers first; up to 5,000 characters of a speaker's longest turns; speakers
/// under 60 words are skipped (with fewer, the model repeated the prompt's example as the summary).
public enum SpeakerSummaries {
    public static let maxCharacters = 5_000
    public static let minimumWords = 60

    public struct Line: Sendable, Equatable {
        public let speaker: String
        public let text: String
    }

    /// nil when the model can be used, else a sentence saying why not.
    public static func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "This Mac cannot run Apple Intelligence."
            case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off in System Settings."
            case .modelNotReady: return "The on-device model is not ready yet (still downloading)."
            @unknown default: return "The on-device model is unavailable (\(reason))."
            }
        }
    }

    /// The text fed to the model for each speaker worth summarizing, biggest talkers first.
    public static func inputs(_ transcript: Transcript) -> [(speaker: String, text: String)] {
        let turns = NameHints.makeTurns(transcript.utterances)
        return transcript.speakers.sorted { $0.talkSeconds > $1.talkSeconds }.compactMap { s in
            let own = turns.filter { $0.speaker == s.id }
            let words = own.reduce(0) { $0 + $1.text.split(separator: " ").count }
            guard words >= minimumWords else { return nil }
            var picked: [(start: Double, text: String)] = []
            var used = 0
            for t in own.sorted(by: { $0.text.count > $1.text.count }) {
                guard used < maxCharacters else { break }
                let room = maxCharacters - used
                let text = t.text.count <= room ? t.text : String(t.text.prefix(room))
                picked.append((t.start, text))
                used += text.count + 1
            }
            // Back in meeting order so the model reads the turns as they happened.
            return (s.id, picked.sorted { $0.start < $1.start }.map(\.text).joined(separator: "\n"))
        }
    }

    static let instructions = """
        You summarize what one participant in a meeting talked about, in a single short sentence of at \
        most 20 words. Describe topics and role: what they asked about, reported or decided. Never name \
        any person, not even the speaker; say "they" instead. Output only the sentence.
        """

    /// One line per summarized speaker. Throws `SummaryError.unavailable` without the model.
    public static func summarize(_ transcript: Transcript) async throws -> [Line] {
        if let reason = unavailableReason() { throw SummaryError.unavailable(reason) }
        var out: [Line] = []
        for input in inputs(transcript) {
            // A fresh session per speaker so one speaker's turns never leak into another's summary.
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: "What this participant said:\n\n\(input.text)")
            let line = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { out.append(Line(speaker: input.speaker, text: line)) }
        }
        return out
    }
}

public enum SummaryError: Error, CustomStringConvertible {
    case unavailable(String)
    public var description: String {
        switch self { case .unavailable(let r): return "Summaries unavailable: \(r)" }
    }
}
