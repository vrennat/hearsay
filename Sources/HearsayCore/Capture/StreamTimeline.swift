import Foundation

/// Keeps one stream's file aligned to meeting time. The first buffer fixes `startOffset`; after that,
/// any gap (the tap goes quiet when nothing plays, a device rebuild, a call-app pause) is filled with
/// silence, and audio that runs ahead of its host time is cut, so frame N of the file is always
/// `startOffset + N / sampleRate` seconds into the meeting, give or take `aheadTolerance`.
public struct StreamTimeline: Sendable, Equatable {
    public let sampleRate: Double
    /// Gaps shorter than this are clock jitter, not missing audio.
    public var tolerance: Double = 0.05
    /// Audio this far ahead of its host time is cut. Larger than `tolerance` so ordinary device-clock
    /// drift (well under 0.5 s an hour) never cuts speech; the silent gaps the tap leaves absorb it.
    /// Without the cut a system track came out 2,083 s long for a 1,239 s meeting (2026-11-02): more
    /// frames arrived than time passed, and padding only ever corrects the other direction.
    public var aheadTolerance: Double = 0.5

    public private(set) var startOffset: Double?
    public private(set) var framesWritten: Int64 = 0
    /// Once a lead passes `aheadTolerance`, cutting continues across buffers until the lead is back
    /// within `tolerance`; stopping at the threshold would leave the track ~0.5 s late for good (with
    /// 10 ms tap buffers) and push the echo filter's lag over its 0.1 s room-on-call line.
    private var cutting = false

    public init(sampleRate: Double) { self.sampleRate = sampleRate }

    /// Where a buffer goes: `pad` frames of silence first, then the buffer from frame `skip` on.
    public struct Placement: Sendable, Equatable {
        public let pad: Int
        public let skip: Int
    }

    /// Call for each buffer before writing it, with the buffer's time in seconds since meeting start.
    /// Counts the silence and the buffer frames kept as written.
    public mutating func place(bufferAt secondsSinceStart: Double, frames: Int) -> Placement {
        guard let start = startOffset else {
            startOffset = max(0, secondsSinceStart)
            framesWritten += Int64(frames)
            return Placement(pad: 0, skip: 0)
        }
        let gap = (secondsSinceStart - start) * sampleRate - Double(framesWritten)
        var placement = Placement(pad: 0, skip: 0)
        if -gap > aheadTolerance * sampleRate { cutting = true }
        if gap > tolerance * sampleRate {
            placement = Placement(pad: Int(gap.rounded()), skip: 0)
            cutting = false
        } else if cutting, -gap > tolerance * sampleRate {
            placement = Placement(pad: 0, skip: min(frames, Int((-gap).rounded())))
        } else {
            cutting = false
        }
        framesWritten += Int64(placement.pad + frames - placement.skip)
        return placement
    }

    public var durationSeconds: Double { Double(framesWritten) / sampleRate }
}
