import AVFoundation
import Foundation

/// `hearsay import`: copy an audio file into a new meeting as its `mic` stream, then run the full
/// post-call pipeline on it (`ProcessPipeline`).
public enum ImportPipeline {
    public static func run(
        audio source: URL, store: MeetingStore, title: String?, options: ProcessOptions = ProcessOptions()
    ) async throws -> String {
        try store.prepare()
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let startedAt = JSONCoding.millisecondRounded((attrs?[.creationDate] as? Date) ?? Date())
        let name = title ?? source.deletingPathExtension().lastPathComponent
        let id = store.newMeetingID(startedAt: startedAt, title: name)

        let audioDir = store.folder(id).appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "wav" : source.pathExtension.lowercased()
        let dest = audioDir.appendingPathComponent("mic.\(ext)")
        try FileManager.default.copyItem(at: source, to: dest)

        let format = try? AVAudioFile(forReading: dest).fileFormat
        let duration = try AudioCompressor.duration(dest)

        let meeting = Meeting(
            id: id, title: name, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(duration),
            status: .recorded, engine: ParakeetTranscriber.engineName,
            streams: [AudioStream(kind: .mic, file: "audio/\(dest.lastPathComponent)", startOffset: 0,
                                  sampleRate: format?.sampleRate, channels: format.map { Int($0.channelCount) })])
        try store.saveMeeting(meeting)

        try await ProcessPipeline.process(meetingID: id, store: store, options: options)
        return id
    }
}
