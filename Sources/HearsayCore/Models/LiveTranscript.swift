import Foundation

/// `live.json`: written every 2 s and on rename while recording. Never touches `meeting.json`.
public struct LiveTranscript: Codable, Sendable, Equatable {
    public var updatedAt: Date
    /// Live speaker id (stream plus diarizer slot, e.g. `mic-1`) to typed name.
    public var speakerNames: [String: String]
    public var lines: [LiveLine]

    public init(updatedAt: Date, speakerNames: [String: String] = [:], lines: [LiveLine] = []) {
        self.updatedAt = updatedAt; self.speakerNames = speakerNames; self.lines = lines
    }

    enum CodingKeys: String, CodingKey { case updatedAt, speakerNames, lines }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        lines = try c.decodeIfPresent([LiveLine].self, forKey: .lines) ?? []
    }
}

public struct LiveLine: Codable, Sendable, Equatable {
    public var speaker: String
    public var stream: StreamKind
    public var start: Double
    public var end: Double
    public var text: String

    public init(speaker: String, stream: StreamKind, start: Double, end: Double, text: String) {
        self.speaker = speaker; self.stream = stream; self.start = start; self.end = end; self.text = text
    }

    enum CodingKeys: String, CodingKey { case speaker, stream, start, end, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker) ?? "unknown"
        stream = try c.decodeIfPresent(StreamKind.self, forKey: .stream) ?? (speaker.hasPrefix("sys") ? .system : .mic)
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? start
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}
