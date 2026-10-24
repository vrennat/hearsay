import AVFoundation
import Foundation

/// Writes one capture stream to an uncompressed Float32 CAF at the device's native rate and channel
/// count (the pipeline downsamples). The file format is fixed by the first device; a rebuilt device
/// with another format is converted to it. Gaps are filled with silence via `StreamTimeline`, so the
/// stream needs only one `startOffset`. Thread-safe: the mic tap and the tap IOProc call `append`
/// from their own threads.
public final class CAFStreamWriter: @unchecked Sendable {
    public let kind: StreamKind
    public let url: URL
    public let format: AVAudioFormat
    private let meetingStartHostTime: UInt64
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var timeline: StreamTimeline
    private var converter: AVAudioConverter?
    private var level = AudioLevel()
    private let log = HSLog("capture")

    /// `meetingStartHostTime` is `HostClock.now()` at meeting start.
    public init(kind: StreamKind, url: URL, sampleRate: Double, channels: Int, meetingStartHostTime: UInt64) throws {
        guard let fmt = Self.makeFormat(sampleRate: sampleRate, channels: channels) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "unsupported capture format \(sampleRate) Hz x \(channels)"])
        }
        self.kind = kind
        self.url = url
        self.format = fmt
        self.meetingStartHostTime = meetingStartHostTime
        self.timeline = StreamTimeline(sampleRate: sampleRate)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(fmt.channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Appends a buffer captured at `hostTime` (mach host ticks). Returns its dBFS.
    @discardableResult
    public func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) -> Float {
        lock.lock(); defer { lock.unlock() }
        guard let file else { return AudioLevel.floor }
        guard let pcm = convert(buffer), pcm.frameLength > 0 else { return AudioLevel.floor }
        let at = HostClock.seconds(from: meetingStartHostTime, to: hostTime)
        let first = timeline.startOffset == nil
        let pad = timeline.silenceBefore(bufferAt: at, frames: Int(pcm.frameLength))
        if first, let offset = timeline.startOffset { saveSidecar(offset: offset) }
        do {
            if pad > 0 { try writeSilence(frames: pad, to: file) }
            try file.write(from: pcm)
        } catch {
            log.error("\(kind.rawValue) write failed: \(error)")
        }
        let db = Self.level(of: pcm)
        level.record(dBFS: db, at: HostClock.seconds(hostTime))
        return db
    }

    public var startOffset: Double? { lock.lock(); defer { lock.unlock() }; return timeline.startOffset }
    public var levelSnapshot: AudioLevel { lock.lock(); defer { lock.unlock() }; return level }
    public var durationSeconds: Double { lock.lock(); defer { lock.unlock() }; return timeline.durationSeconds }

    /// Closes the file. A stream that never got a buffer deletes its empty file and returns nil.
    public func finish() -> AudioStream? {
        lock.lock(); defer { lock.unlock() }
        file = nil
        try? FileManager.default.removeItem(at: Self.sidecarURL(for: url))
        guard let offset = timeline.startOffset else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return AudioStream(kind: kind, file: "audio/\(url.lastPathComponent)", startOffset: offset,
                           sampleRate: format.sampleRate, channels: Int(format.channelCount))
    }

    /// `audio/<kind>.json`: the stream record, written once at the first buffer so crash recovery
    /// keeps the start offset without touching `meeting.json` mid-recording. Deleted at `finish()`.
    public static func sidecarURL(for caf: URL) -> URL {
        caf.deletingPathExtension().appendingPathExtension("json")
    }

    private func saveSidecar(offset: Double) {
        let stream = AudioStream(kind: kind, file: "audio/\(url.lastPathComponent)", startOffset: offset,
                                 sampleRate: format.sampleRate, channels: Int(format.channelCount))
        let dest = Self.sidecarURL(for: url)
        // Synchronous: once per stream, and it must land before `finish()` deletes it.
        if let data = try? JSONCoding.encoder().encode(stream) { try? AtomicFile.write(data, to: dest) }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            log.info("\(kind.rawValue) converting \(buffer.format) to file format \(format)")
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let err { log.error("\(kind.rawValue) convert failed: \(err)"); return nil }
        return out
    }

    private func writeSilence(frames: Int, to file: AVAudioFile) throws {
        let chunk = 16_384
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else { return }
        var left = frames
        while left > 0 {
            let n = min(chunk, left)
            buf.frameLength = AVAudioFrameCount(n)
            for c in 0..<Int(format.channelCount) { buf.floatChannelData![c].update(repeating: 0, count: n) }
            try file.write(from: buf)
            left -= n
        }
    }

    /// `AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)` returns nil above 2 channels
    /// (a 4-input interface like the MOTU M4 broke every mic recording), so wider formats get a
    /// discrete-in-order layout.
    static func makeFormat(sampleRate: Double, channels: Int) -> AVAudioFormat? {
        let n = AVAudioChannelCount(max(1, channels))
        if n <= 2 {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: n, interleaved: false)
        }
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | n) else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
    }

    static func level(of buf: AVAudioPCMBuffer) -> Float {
        guard let data = buf.floatChannelData else { return AudioLevel.floor }
        let chans = (0..<Int(buf.format.channelCount)).map { UnsafePointer(data[$0]) }
        return AudioLevel.dBFS(channels: chans, frames: Int(buf.frameLength))
    }
}
