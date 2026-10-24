import Foundation

/// Per-stream level the capture exposes: current dBFS, last buffer time and last "heard" (loud) buffer
/// time, which end detection reads. Times are host seconds (`HostClock`).
public struct AudioLevel: Sendable, Equatable {
    /// "Heard": call apps play silence for the whole call, a quiet headset mic sat near -63 dBFS,
    /// office talk ran about -47.
    public static let loudThreshold: Float = -46
    public static let floor: Float = -100

    public private(set) var dBFS: Float = AudioLevel.floor
    public private(set) var lastBufferAt: Double?
    public private(set) var lastLoudAt: Double?

    public init() {}

    public mutating func record(dBFS level: Float, at time: Double) {
        dBFS = level
        lastBufferAt = time
        if level > Self.loudThreshold { lastLoudAt = time }
    }

    /// Reads the floor once buffers stop for 0.3 s.
    public func displayLevel(now: Double) -> Float {
        guard let last = lastBufferAt, now - last < 0.3 else { return Self.floor }
        return dBFS
    }

    /// RMS over the channels that carry signal (`ChannelFold`), in dBFS. Averaging dead interface
    /// inputs in read a 4-input device 6 dB low and tripped the "no microphone audio" warning.
    public static func dBFS(channels: [UnsafePointer<Float>], frames: Int) -> Float {
        ChannelFold.dBFS(channels, frames: frames, floor: floor)
    }
}
