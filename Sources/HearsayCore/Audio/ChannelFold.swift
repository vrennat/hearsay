import AVFoundation

/// Folds a multi-channel buffer to mono by averaging only the channels that carry signal.
///
/// Audio interfaces expose every input as a channel (a MOTU showed 4 inputs with the mic on the
/// first and digital silence, about -113 dBFS, on the rest). A plain average of all channels then
/// loses 12 dB on the voice, which put real recordings under the transcription gate. Channels whose
/// RMS over the buffer is below `activeFloorDBFS` are dropped from the mix; if none is active the
/// mix is plain silence either way, so all channels are averaged.
public enum ChannelFold {
    /// Below this a channel is treated as dead for the buffer. A quiet headset mic's noise floor sat
    /// near -63 dBFS; unused interface inputs sit near -113.
    public static let activeFloorDBFS: Float = -90

    /// Mean square per channel.
    static func powers(_ channels: [UnsafePointer<Float>], frames: Int) -> [Float] {
        channels.map { ch in
            var sum: Float = 0
            for i in 0..<frames { sum += ch[i] * ch[i] }
            return sum / Float(max(1, frames))
        }
    }

    /// Indices of the channels above `activeFloorDBFS` for these frames.
    public static func activeChannels(_ channels: [UnsafePointer<Float>], frames: Int) -> [Int] {
        let floorPower = powf(10, activeFloorDBFS / 10)
        return powers(channels, frames: frames).enumerated().filter { $0.element > floorPower }.map(\.offset)
    }

    /// RMS in dBFS over the active channels (all channels when none is active), floored at `floor`.
    public static func dBFS(_ channels: [UnsafePointer<Float>], frames: Int, floor: Float) -> Float {
        guard frames > 0, !channels.isEmpty else { return floor }
        let p = powers(channels, frames: frames)
        let active = activeChannels(channels, frames: frames)
        let used = active.isEmpty ? Array(p.indices) : active
        let mean = used.reduce(Float(0)) { $0 + p[$1] } / Float(used.count)
        guard mean > 0 else { return floor }
        return max(floor, 10 * log10(mean))
    }

    /// Per-channel RMS in dBFS, for logging what a device delivers.
    public static func channelLevels(_ channels: [UnsafePointer<Float>], frames: Int, floor: Float = -120) -> [Float] {
        powers(channels, frames: frames).map { $0 > 0 ? max(floor, 10 * log10($0)) : floor }
    }

    /// A mono Float32 buffer at the source rate holding the active-channel mean. A mono input is
    /// returned as is.
    public static func mono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        let n = Int(buffer.frameLength)
        guard format.channelCount > 1 else { return buffer }
        guard let data = buffer.floatChannelData,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(max(1, n)))
        else { return nil }
        out.frameLength = AVAudioFrameCount(n)
        let channels = (0..<Int(format.channelCount)).map { UnsafePointer(data[$0]) }
        let active = activeChannels(channels, frames: n)
        let used = active.isEmpty ? Array(channels.indices) : active
        let scale = 1 / Float(used.count)
        let o = out.floatChannelData![0]
        o.update(repeating: 0, count: n)
        for c in used { let ch = channels[c]; for i in 0..<n { o[i] += ch[i] * scale } }
        return out
    }
}
