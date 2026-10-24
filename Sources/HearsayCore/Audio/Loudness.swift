import Foundation

/// 10 ms RMS loudness in dBFS. One definition of "loud" shared by the transcription gate, the echo
/// filter, end detection and the level meter.
public enum Loudness {
    /// Seconds per loudness frame.
    public static let frameSeconds = 0.01
    /// A frame above this is "heard". Spec: a quiet headset mic sat near -63 dBFS, office talk ran
    /// about -47 (90th percentile -34).
    public static let loudDBFS: Float = -46
    /// Value used for digital silence and for padding before a stream's `startOffset`.
    public static let floorDBFS: Float = -120

    /// Frame count for a duration in seconds.
    public static func frames(_ seconds: Double) -> Int { Int((seconds / frameSeconds).rounded()) }

    /// RMS dBFS per 10 ms frame of mono samples at `sampleRate`. A trailing partial frame is included.
    public static func curve(_ samples: [Float], sampleRate: Double = AudioLoader.sampleRate) -> [Float] {
        let n = max(1, Int(sampleRate * frameSeconds))
        guard !samples.isEmpty else { return [] }
        var out: [Float] = []
        out.reserveCapacity(samples.count / n + 1)
        samples.withUnsafeBufferPointer { p in
            var i = 0
            while i < p.count {
                let end = min(i + n, p.count)
                var sum: Float = 0
                for j in i..<end { sum += p[j] * p[j] }
                let rms = (sum / Float(end - i)).squareRoot()
                out.append(rms > 0 ? max(floorDBFS, 20 * log10(rms)) : floorDBFS)
                i = end
            }
        }
        return out
    }

    /// Curve placed in meeting time: `startOffset` seconds of floor frames, then the track's curve.
    public static func meetingCurve(_ samples: [Float], startOffset: Double) -> [Float] {
        [Float](repeating: floorDBFS, count: max(0, frames(startOffset))) + curve(samples)
    }

    public static func loudSeconds(_ curve: [Float], above threshold: Float = loudDBFS) -> Double {
        Double(curve.reduce(0) { $0 + ($1 > threshold ? 1 : 0) }) * frameSeconds
    }

    /// The gate's own "loud" line for one track: 10 dB above its noise floor (the 20th percentile of
    /// frames above the padding floor), clamped between -70 and `loudDBFS`. A MOTU interface at its
    /// default gain put speech at -58 to -50 dBFS over a -63 floor, under the fixed line that a
    /// hotter mic was calibrated on; the fixed line stays for echo, end detection and the meter.
    public static let gateHeadroomDB: Float = 10
    public static let gateFloorDBFS: Float = -70

    public static func gateThreshold(_ curve: [Float]) -> Float {
        let real = curve.filter { $0 > floorDBFS + 1 }.sorted()
        guard !real.isEmpty else { return loudDBFS }
        let noise = real[min(real.count - 1, Int(Double(real.count) * 0.2))]
        return min(loudDBFS, max(gateFloorDBFS, noise + gateHeadroomDB))
    }

    /// Spec step 1 (amended 2026-10-23): transcribe a track with at least `shortGateSeconds` loud
    /// seconds or 5% of its length, whichever is more, capped at `gateSeconds` and never more than a
    /// quarter of the track. A 49 s test with three spoken seconds passes; a near-silent hour does not.
    public static let gateSeconds = 20.0
    public static let shortGateSeconds = 3.0

    public static func requiredLoudSeconds(duration: Double) -> Double {
        min(gateSeconds, max(shortGateSeconds, duration / 20), duration / 4)
    }

    public static func passesGate(_ curve: [Float]) -> Bool {
        guard !curve.isEmpty else { return false }
        let duration = Double(curve.count) * frameSeconds
        return loudSeconds(curve, above: gateThreshold(curve)) >= requiredLoudSeconds(duration: duration)
    }
}
