import Foundation

/// One decoded stream: mono 16 kHz samples plus where they sit in meeting time.
public struct Track: Sendable {
    public let kind: StreamKind
    public let startOffset: Double
    public let samples: [Float]

    public var duration: Double { Double(samples.count) / AudioLoader.sampleRate }
    /// Loudness in meeting time (padded by `startOffset`).
    public var meetingCurve: [Float] { Loudness.meetingCurve(samples, startOffset: startOffset) }

    /// Samples between two meeting times, clamped to the track.
    public func slice(_ start: Double, _ end: Double) -> ArraySlice<Float> {
        let a = max(0, min(samples.count, Int((start - startOffset) * AudioLoader.sampleRate)))
        let b = max(a, min(samples.count, Int((end - startOffset) * AudioLoader.sampleRate)))
        return samples[a..<b]
    }

    /// The first stream of each kind in `meeting.json`, decoded. Missing files are skipped and logged.
    public static func load(_ meeting: Meeting, store: MeetingStore) throws -> [Track] {
        var seen: Set<StreamKind> = []
        var out: [Track] = []
        for s in meeting.streams {
            guard !seen.contains(s.kind) else {
                HearsayCore.logger("pipeline").warning("\(meeting.id, privacy: .public): extra \(s.kind.rawValue, privacy: .public) stream \(s.file, privacy: .public) ignored")
                continue
            }
            let url = store.folder(meeting.id).appendingPathComponent(s.file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                HearsayCore.logger("pipeline").warning("\(meeting.id, privacy: .public): missing \(s.file, privacy: .public)")
                continue
            }
            seen.insert(s.kind)
            out.append(Track(kind: s.kind, startOffset: s.startOffset, samples: try AudioLoader.loadMono16k(url)))
        }
        return out
    }
}
