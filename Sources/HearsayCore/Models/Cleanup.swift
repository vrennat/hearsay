import Foundation

/// `cleanup.json`. Applies only while `sourceProcessedAt` equals `Transcript.processedAt`.
public struct Cleanup: Codable, Sendable, Equatable {
    public var sourceProcessedAt: Date
    public var createdAt: Date?
    /// What made the cleanup, shown as `cleaned_by:` in `transcript.md`.
    public var method: String?
    /// Cleaned text per utterance, same order and count as `Transcript.utterances`.
    public var utterances: [CleanedUtterance]

    public init(sourceProcessedAt: Date, createdAt: Date? = nil, method: String? = nil, utterances: [CleanedUtterance]) {
        self.sourceProcessedAt = sourceProcessedAt; self.createdAt = createdAt; self.method = method
        self.utterances = utterances
    }

    enum CodingKeys: String, CodingKey { case sourceProcessedAt, createdAt, method, utterances }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceProcessedAt = try c.decodeIfPresent(Date.self, forKey: .sourceProcessedAt) ?? Date(timeIntervalSince1970: 0)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        method = try c.decodeIfPresent(String.self, forKey: .method)
        utterances = try c.decodeIfPresent([CleanedUtterance].self, forKey: .utterances) ?? []
    }

    public func matches(_ transcript: Transcript) -> Bool {
        abs(sourceProcessedAt.timeIntervalSince(transcript.processedAt)) < 0.0005
    }
}

public struct CleanedUtterance: Codable, Sendable, Equatable {
    /// Index into `Transcript.utterances`.
    public var index: Int
    public var text: String

    public init(index: Int, text: String) { self.index = index; self.text = text }

    enum CodingKeys: String, CodingKey { case index, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? -1
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}
