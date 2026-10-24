import Foundation

/// `transcript.json`: the single source of truth for every rendered Markdown file.
public struct Transcript: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var engine: String
    public var diarizer: String?
    public var processedAt: Date
    public var speakers: [Speaker]
    public var utterances: [Utterance]

    public init(
        formatVersion: Int = Transcript.currentFormatVersion, engine: String, diarizer: String? = nil,
        processedAt: Date, speakers: [Speaker], utterances: [Utterance]
    ) {
        self.formatVersion = formatVersion; self.engine = engine; self.diarizer = diarizer
        self.processedAt = processedAt; self.speakers = speakers; self.utterances = utterances
    }

    enum CodingKeys: String, CodingKey { case formatVersion, engine, diarizer, processedAt, speakers, utterances }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? "unknown"
        diarizer = try c.decodeIfPresent(String.self, forKey: .diarizer)
        processedAt = try c.decodeIfPresent(Date.self, forKey: .processedAt) ?? Date(timeIntervalSince1970: 0)
        speakers = try c.decodeIfPresent([Speaker].self, forKey: .speakers) ?? []
        utterances = try c.decodeIfPresent([Utterance].self, forKey: .utterances) ?? []
    }

    public func speaker(_ id: String) -> Speaker? { speakers.first { $0.id == id } }
}

public struct Speaker: Codable, Sendable, Equatable {
    /// `mic-1`, `sys-2`, ...
    public var id: String
    public var stream: StreamKind
    /// `Me`, `Room N`, `Remote N`.
    public var defaultLabel: String
    public var talkSeconds: Double
    /// CAM++ voice embedding, when computed.
    public var voice: [Float]?

    public init(id: String, stream: StreamKind, defaultLabel: String, talkSeconds: Double, voice: [Float]? = nil) {
        self.id = id; self.stream = stream; self.defaultLabel = defaultLabel
        self.talkSeconds = talkSeconds; self.voice = voice
    }

    enum CodingKeys: String, CodingKey { case id, stream, defaultLabel, talkSeconds, voice }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? "unknown"
        stream = try c.decodeIfPresent(StreamKind.self, forKey: .stream) ?? (id.hasPrefix("sys") ? .system : .mic)
        defaultLabel = try c.decodeIfPresent(String.self, forKey: .defaultLabel) ?? id
        talkSeconds = try c.decodeIfPresent(Double.self, forKey: .talkSeconds) ?? 0
        voice = try c.decodeIfPresent([Float].self, forKey: .voice)
    }
}

public struct Utterance: Codable, Sendable, Equatable {
    public var speaker: String
    public var stream: StreamKind
    /// Seconds from meeting start.
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [Word]

    public init(speaker: String, stream: StreamKind, start: Double, end: Double, text: String, words: [Word] = []) {
        self.speaker = speaker; self.stream = stream; self.start = start; self.end = end
        self.text = text; self.words = words
    }

    enum CodingKeys: String, CodingKey { case speaker, stream, start, end, text, words }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker) ?? "unknown"
        stream = try c.decodeIfPresent(StreamKind.self, forKey: .stream) ?? (speaker.hasPrefix("sys") ? .system : .mic)
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? start
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        words = try c.decodeIfPresent([Word].self, forKey: .words) ?? []
    }
}

public struct Word: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text; self.start = start; self.end = end
    }

    enum CodingKeys: String, CodingKey { case text, word, start, end }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text)
            ?? c.decodeIfPresent(String.self, forKey: .word) ?? ""
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? start
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
    }
}
