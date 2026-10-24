import Foundation

/// `meeting.json`. Every field but `id` is optional on decode so folders from the old app open as-is.
public struct Meeting: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var status: MeetingStatus
    public var error: String?
    public var engine: String?
    public var streams: [AudioStream]
    public var speakerNames: [String: String]
    public var echoCancellation: Bool?
    public var appVersion: String?
    public var attendees: [String]
    public var me: String?
    public var audioRemovedAt: Date?
    /// Set when the user typed the title (window or `hearsay title <id> <title>`); such a meeting is
    /// never retitled by `TitleGenerator`. Missing in older folders, read as false.
    public var titleEditedByUser: Bool

    public init(
        id: String, title: String, startedAt: Date, endedAt: Date? = nil,
        status: MeetingStatus = .recording, error: String? = nil, engine: String? = nil,
        streams: [AudioStream] = [], speakerNames: [String: String] = [:],
        echoCancellation: Bool? = nil, appVersion: String? = HearsayCore.version,
        attendees: [String] = [], me: String? = nil, audioRemovedAt: Date? = nil,
        titleEditedByUser: Bool = false
    ) {
        self.id = id; self.title = title; self.startedAt = startedAt; self.endedAt = endedAt
        self.status = status; self.error = error; self.engine = engine; self.streams = streams
        self.speakerNames = speakerNames; self.echoCancellation = echoCancellation
        self.appVersion = appVersion; self.attendees = attendees; self.me = me
        self.audioRemovedAt = audioRemovedAt; self.titleEditedByUser = titleEditedByUser
    }

    enum CodingKeys: String, CodingKey {
        case id, title, startedAt, endedAt, status, error, engine, streams, speakerNames
        case echoCancellation, appVersion, attendees, me, audioRemovedAt, titleEditedByUser
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date(timeIntervalSince1970: 0)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        status = try c.decodeIfPresent(MeetingStatus.self, forKey: .status) ?? .recorded
        error = try c.decodeIfPresent(String.self, forKey: .error)
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        streams = try c.decodeIfPresent([AudioStream].self, forKey: .streams) ?? []
        speakerNames = try c.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        echoCancellation = try c.decodeIfPresent(Bool.self, forKey: .echoCancellation)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion)
        attendees = try c.decodeIfPresent([String].self, forKey: .attendees) ?? []
        me = try c.decodeIfPresent(String.self, forKey: .me)
        audioRemovedAt = try c.decodeIfPresent(Date.self, forKey: .audioRemovedAt)
        titleEditedByUser = try c.decodeIfPresent(Bool.self, forKey: .titleEditedByUser) ?? false
    }

    public var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}

public enum StreamKind: String, Codable, Sendable { case mic, system }

public struct AudioStream: Codable, Sendable, Equatable {
    public var kind: StreamKind
    /// Path relative to the meeting folder, e.g. `audio/mic.m4a`.
    public var file: String
    /// Seconds from meeting start to the first sample.
    public var startOffset: Double
    public var sampleRate: Double?
    public var channels: Int?

    public init(kind: StreamKind, file: String, startOffset: Double = 0, sampleRate: Double? = nil, channels: Int? = nil) {
        self.kind = kind; self.file = file; self.startOffset = startOffset
        self.sampleRate = sampleRate; self.channels = channels
    }

    enum CodingKeys: String, CodingKey { case kind, file, startOffset, sampleRate, channels }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(StreamKind.self, forKey: .kind) ?? .mic
        file = try c.decodeIfPresent(String.self, forKey: .file) ?? ""
        startOffset = try c.decodeIfPresent(Double.self, forKey: .startOffset) ?? 0
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate)
        channels = try c.decodeIfPresent(Int.self, forKey: .channels)
    }
}
