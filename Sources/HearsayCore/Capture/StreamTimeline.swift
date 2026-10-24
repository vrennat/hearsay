import Foundation

/// Keeps one stream's file aligned to meeting time. The first buffer fixes `startOffset`; after that,
/// any gap (the tap goes quiet when nothing plays, a device rebuild, a call-app pause) is filled with
/// silence, so frame N of the file is always `startOffset + N / sampleRate` seconds into the meeting.
public struct StreamTimeline: Sendable, Equatable {
    public let sampleRate: Double
    /// Gaps shorter than this are clock jitter, not missing audio.
    public var tolerance: Double = 0.05

    public private(set) var startOffset: Double?
    public private(set) var framesWritten: Int64 = 0

    public init(sampleRate: Double) { self.sampleRate = sampleRate }

    /// Call for each buffer before writing it, with the buffer's time in seconds since meeting start.
    /// Returns how many frames of silence to write first. Counts the buffer's own frames as written.
    public mutating func silenceBefore(bufferAt secondsSinceStart: Double, frames: Int) -> Int {
        defer { framesWritten += Int64(frames) }
        guard let start = startOffset else {
            startOffset = max(0, secondsSinceStart)
            return 0
        }
        let gap = (secondsSinceStart - start) * sampleRate - Double(framesWritten)
        guard gap > tolerance * sampleRate else { return 0 }
        let pad = Int(gap.rounded())
        framesWritten += Int64(pad)
        return pad
    }

    public var durationSeconds: Double { Double(framesWritten) / sampleRate }
}
