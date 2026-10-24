import AVFoundation
import Foundation

public enum CompressionError: Error, CustomStringConvertible {
    case failed(String)
    case durationMismatch(source: Double, output: Double)
    public var description: String {
        switch self {
        case .failed(let s): return "Compression failed: \(s)"
        case .durationMismatch(let a, let b): return String(format: "Compressed length %.2fs differs from source %.2fs", b, a)
        }
    }
}

/// Re-encodes a track to AAC `.m4a` at 64 kbps per channel (spec: CAF is about 1.7 GB an hour).
public enum AudioCompressor {
    public static let bitsPerChannel = 64_000
    /// The output must be within this of the source length or it is discarded.
    public static let tolerance = 0.5

    public static func duration(_ url: URL) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        return Double(f.length) / f.fileFormat.sampleRate
    }

    /// Writes `output` and checks its length. Leaves the source alone; throws and removes `output`
    /// on any failure.
    public static func compress(_ source: URL, to output: URL) async throws {
        let srcFile = try AVAudioFile(forReading: source)
        let channels = Int(srcFile.fileFormat.channelCount)
        // AAC encoders top out at 48 kHz.
        let rate = min(srcFile.fileFormat.sampleRate, 48_000)
        try? FileManager.default.removeItem(at: output)
        if channels > 2 {
            try compressFolded(srcFile, to: output)
            try checkLength(source, output)
            return
        }

        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CompressionError.failed("no audio track") }
        let reader = try AVAssetReader(asset: asset)
        let readerOut = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
        ])
        reader.add(readerOut)
        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitsPerChannel * channels,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard reader.startReading() else { throw CompressionError.failed(reader.error?.localizedDescription ?? "reader") }
        guard writer.startWriting() else { throw CompressionError.failed(writer.error?.localizedDescription ?? "writer") }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "com.tannervass.hearsay.compress")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if let buf = readerOut.copyNextSampleBuffer() {
                        if !input.append(buf) { reader.cancelReading(); input.markAsFinished(); done.resume(); return }
                    } else {
                        input.markAsFinished(); done.resume(); return
                    }
                }
            }
        }
        await writer.finishWriting()
        if writer.status != .completed || reader.status == .failed {
            try? FileManager.default.removeItem(at: output)
            throw CompressionError.failed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "unknown")
        }
        let a = try duration(source), b = try duration(output)
        guard abs(a - b) <= tolerance else {
            try? FileManager.default.removeItem(at: output)
            throw CompressionError.durationMismatch(source: a, output: b)
        }
    }

    /// A track with more than two channels is an audio interface's input bank (a 4-input MOTU with
    /// the mic on input 1). AVAssetWriter has no AAC layout for discrete inputs and the dead inputs are
    /// not worth keeping, so the track is folded to mono with `ChannelFold` (active channels only)
    /// and written through AVAudioFile. Needs a source rate of 48 kHz or less.
    static func compressFolded(_ src: AVAudioFile, to output: URL) throws {
        let rate = src.processingFormat.sampleRate
        guard rate <= 48_000 else { throw CompressionError.failed("\(Int(rate)) Hz multi-channel source") }
        let out = try AVAudioFile(forWriting: output, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitsPerChannel,
        ])
        let chunk: AVAudioFrameCount = 32_768
        while src.framePosition < src.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: chunk) else { throw CompressionError.failed("buffer") }
            try src.read(into: buf, frameCount: chunk)
            guard buf.frameLength > 0 else { break }
            guard let mono = ChannelFold.mono(buf) else { throw CompressionError.failed("fold") }
            try out.write(from: mono)
        }
    }

    static func checkLength(_ source: URL, _ output: URL) throws {
        let a = try duration(source), b = try duration(output)
        guard abs(a - b) <= tolerance else {
            try? FileManager.default.removeItem(at: output)
            throw CompressionError.durationMismatch(source: a, output: b)
        }
    }

    /// Compresses every stream that is not already `.m4a` (or `.m4a.enc`), repoints `meeting.json`,
    /// then deletes the original. An encrypted source (`.caf.enc`) is decrypted to a private temp
    /// file for AVAssetReader and its output is encrypted again. With `encrypt` the new `.m4a` is
    /// written as `.m4a.enc`. A failed stream keeps its original file and is logged.
    @discardableResult
    public static func compressMeeting(_ id: String, store: MeetingStore, encrypt: Bool = false) async throws -> Int {
        var meeting = try store.loadMeeting(id)
        let folder = store.folder(id)
        let fm = FileManager.default
        var count = 0
        for (i, s) in meeting.streams.enumerated() {
            let sealed = EncryptedFile.isEncrypted(URL(fileURLWithPath: s.file))
            let base = sealed ? (s.file as NSString).deletingPathExtension : s.file
            guard (base as NSString).pathExtension.lowercased() != "m4a" else { continue }
            let src = folder.appendingPathComponent(s.file)
            guard fm.fileExists(atPath: src.path) else { continue }
            let plainRel = ((base as NSString).deletingPathExtension as NSString).appendingPathExtension("m4a")!
            let seal = encrypt || sealed
            let rel = seal ? plainRel + "." + EncryptedFile.suffix : plainRel
            let plainDst = folder.appendingPathComponent(plainRel)
            var temp: URL?
            defer { if let temp { try? fm.removeItem(at: temp) } }
            do {
                var input = src
                if sealed {
                    let dir = try AudioVault.privateTemp()
                    temp = dir
                    input = dir.appendingPathComponent((base as NSString).lastPathComponent)
                    try EncryptedFile.decryptFile(src, to: input, key: AudioKey.existing())
                }
                try await compress(input, to: plainDst)
                if seal {
                    try EncryptedFile.encryptFile(plainDst, to: folder.appendingPathComponent(rel), key: AudioKey.getOrCreate())
                    try fm.removeItem(at: plainDst)
                }
            } catch {
                try? fm.removeItem(at: plainDst)
                HearsayCore.logger("compress").error("\(id, privacy: .public) \(s.file, privacy: .public): \(String(describing: error), privacy: .public)")
                continue
            }
            meeting.streams[i].file = rel
            try store.saveMeeting(meeting)  // repoint before deleting, so a crash never loses the track
            try fm.removeItem(at: src)
            count += 1
        }
        return count
    }
}
