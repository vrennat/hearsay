import AVFoundation
import Foundation

/// `meeting.json` is written exactly twice per recording: once at start (`recording`) and once at stop
/// (`recorded`, `endedAt`, `streams`). Never in between, so a crash leaves the start record and the CAFs.
public enum RecordingLifecycle {
    public static let interruptedError = "interrupted"

    /// The date-time placeholder title used until the calendar lookup exists.
    public static func placeholderTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d HH:mm"
        return "Meeting \(f.string(from: date))"
    }

    /// Creates the folder and `audio/`, writes `meeting.json` with status `recording`.
    public static func begin(store: MeetingStore, startedAt: Date, title: String? = nil) throws -> Meeting {
        try store.prepare()
        let start = JSONCoding.millisecondRounded(startedAt)
        let name = title ?? placeholderTitle(for: start)
        let id = store.newMeetingID(startedAt: start, title: name)
        try FileManager.default.createDirectory(
            at: store.folder(id).appendingPathComponent("audio", isDirectory: true), withIntermediateDirectories: true)
        let meeting = Meeting(id: id, title: name, startedAt: start, status: .recording, engine: "parakeet",
                              echoCancellation: false)
        try store.saveMeeting(meeting)
        return meeting
    }

    /// The single stop write: `recorded`, `endedAt`, the streams that got audio.
    public static func finish(_ meeting: Meeting, store: MeetingStore, endedAt: Date, streams: [AudioStream],
                              error: String? = nil) throws -> Meeting {
        var m = meeting
        m.status = .recorded
        m.endedAt = JSONCoding.millisecondRounded(endedAt)
        m.streams = streams.sorted { $0.kind == .mic && $1.kind != .mic }
        m.error = error
        try store.saveMeeting(m)
        return m
    }

    /// At launch: every meeting still `recording` was cut off by a crash or kill. Mark it `recorded`
    /// with error `interrupted`, fill in the streams from the CAFs on disk and `endedAt` from the newest
    /// file, and return the ids to process. `skip` holds ids this process is recording itself.
    public static func recoverInterrupted(store: MeetingStore, skip: Set<String> = []) -> [String] {
        let log = HSLog("recovery")
        var recovered: [String] = []
        for var m in store.loadAllMeetings() where m.status == .recording && !skip.contains(m.id) {
            let audio = store.folder(m.id).appendingPathComponent("audio", isDirectory: true)
            if m.streams.isEmpty { m.streams = streamsOnDisk(audio) }
            if m.endedAt == nil {
                let dates = m.streams.compactMap {
                    (try? FileManager.default.attributesOfItem(
                        atPath: store.folder(m.id).appendingPathComponent($0.file).path))?[.modificationDate] as? Date
                }
                m.endedAt = JSONCoding.millisecondRounded(dates.max() ?? m.startedAt)
            }
            m.status = .recorded
            m.error = interruptedError
            do {
                try store.saveMeeting(m)
                recovered.append(m.id)
                log.info("Marked \(m.id) interrupted (\(m.streams.count) streams)")
            } catch {
                log.error("Could not mark \(m.id) interrupted: \(error)")
            }
        }
        return recovered
    }

    /// Streams from the CAFs on disk, with the start offsets their writers saved in `audio/<kind>.json`
    /// (see `CAFStreamWriter`). Without a sidecar the offset is 0.
    static func streamsOnDisk(_ audio: URL) -> [AudioStream] {
        [StreamKind.mic, .system].compactMap { kind in
            let url = audio.appendingPathComponent("\(kind.rawValue).caf")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            if let data = try? Data(contentsOf: CAFStreamWriter.sidecarURL(for: url)),
               let s = try? JSONCoding.decoder().decode(AudioStream.self, from: data) {
                return s
            }
            let f = try? AVAudioFile(forReading: url)
            return AudioStream(kind: kind, file: "audio/\(kind.rawValue).caf", startOffset: 0,
                               sampleRate: f?.fileFormat.sampleRate, channels: f.map { Int($0.fileFormat.channelCount) })
        }
    }
}
