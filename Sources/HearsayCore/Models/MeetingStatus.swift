import Foundation

public enum MeetingStatus: String, Codable, Sendable, CaseIterable {
    case recording, recorded, processing, done, failed

    /// Unknown values from a newer or older app read as `failed` instead of breaking the load.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MeetingStatus(rawValue: raw) ?? .failed
    }
}
