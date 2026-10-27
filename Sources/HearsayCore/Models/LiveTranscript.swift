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

    enum CodingKeys: String, CodingKey { case updatedAt, speakerNames, lines, names, spans }

    /// The old app's shape: `names: [{name, voice: {slot, stream}}]` and `spans: [{start, end, voice}]`,
    /// no text, 0-based slots. Read into the same ids (`sys-1` is old slot 0) so `LiveNameMapper` can
    /// carry its names into the final transcript. Checked against a real old-app sync (2026-10-23).
    struct OldVoice: Decodable { var slot: Int; var stream: StreamKind; var id: String { "\(stream == .mic ? "mic" : "sys")-\(slot + 1)" } }
    struct OldName: Decodable { var name: String; var voice: OldVoice }
    struct OldSpan: Decodable { var start: Double; var end: Double; var voice: OldVoice }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(timeIntervalSince1970: 0)
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        lines = try c.decodeIfPresent([LiveLine].self, forKey: .lines) ?? []
        if speakerNames.isEmpty, let old = try? c.decodeIfPresent([OldName].self, forKey: .names) {
            for n in old where !n.name.trimmingCharacters(in: .whitespaces).isEmpty { speakerNames[n.voice.id] = n.name }
        }
        if lines.isEmpty, let old = try? c.decodeIfPresent([OldSpan].self, forKey: .spans) {
            lines = old.map { LiveLine(speaker: $0.voice.id, stream: $0.voice.stream, start: $0.start, end: $0.end, text: "") }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(speakerNames, forKey: .speakerNames)
        try c.encode(lines, forKey: .lines)
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
