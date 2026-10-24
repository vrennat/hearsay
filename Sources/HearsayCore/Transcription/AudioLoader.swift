import AudioToolbox
import AVFoundation

public enum AudioLoaderError: Error, CustomStringConvertible {
    case unreadable(URL, String)
    public var description: String {
        switch self { case .unreadable(let u, let why): return "Cannot decode \(u.path): \(why)" }
    }
}

/// Decodes any file AVFoundation reads into mono 16 kHz Float samples. Multi-channel files are folded
/// with `ChannelFold` (active channels only) before resampling. A `.enc` file (encrypted
/// recording) is decrypted in memory with the Keychain audio key and decoded from memory through
/// Audio File Services callbacks, so no plaintext reaches the disk.
public enum AudioLoader {
    public static let sampleRate = 16_000.0
    static let chunk: AVAudioFrameCount = 32_768

    public static func loadMono16k(_ url: URL) throws -> [Float] {
        if EncryptedFile.isEncrypted(url) {
            let data = try EncryptedFile.decryptFile(url, key: AudioKey.existing())
            return try loadMono16k(data: data, typeHint: url.deletingPathExtension().pathExtension, name: url)
        }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw AudioLoaderError.unreadable(url, error.localizedDescription)
        }
        return try convert(url, format: file.processingFormat, length: file.length) { buf in
            // AVAudioFile.read throws at end of file, so stop on the position instead.
            if file.framePosition >= file.length { return }
            try file.read(into: buf, frameCount: chunk)
        }
    }

    /// Decodes an in-memory audio file (CAF, M4A, WAV...). `typeHint` is its extension.
    public static func loadMono16k(data: Data, typeHint: String, name: URL) throws -> [Float] {
        let reader = try MemoryAudioFile(data: data, typeHint: typeHint, name: name)
        defer { reader.close() }
        return try convert(name, format: reader.format, length: reader.length) { try reader.read(into: $0) }
    }

    /// `fill` reads up to `chunk` frames into the buffer; zero frames means the end.
    static func convert(_ url: URL, format: AVAudioFormat, length: AVAudioFramePosition,
                        fill: (AVAudioPCMBuffer) throws -> Void) throws -> [Float] {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let monoSource = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoSource, to: target)
        else { throw AudioLoaderError.unreadable(url, "no converter") }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(max(0, length)) * sampleRate / format.sampleRate) + 1024)
        var readError: Error?
        var finished = false

        while true {
            let outCapacity = AVAudioFrameCount(Double(chunk) * sampleRate / format.sampleRate) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else { break }
            var convError: NSError?
            let status = converter.convert(to: out, error: &convError) { _, inputStatus in
                if finished { inputStatus.pointee = .endOfStream; return nil }
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
                    inputStatus.pointee = .endOfStream; return nil
                }
                do { try fill(inBuf) } catch { readError = error }
                if inBuf.frameLength == 0 { finished = true; inputStatus.pointee = .endOfStream; return nil }
                // Fold to mono here, not in the converter: its downmix averages dead channels in.
                guard let mono = ChannelFold.mono(inBuf) else { inputStatus.pointee = .endOfStream; return nil }
                inputStatus.pointee = .haveData
                return mono
            }
            if let convError { throw AudioLoaderError.unreadable(url, convError.localizedDescription) }
            if let readError { throw AudioLoaderError.unreadable(url, readError.localizedDescription) }
            if let data = out.floatChannelData, out.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
            }
            if status == .endOfStream || status == .error { break }
        }
        return samples
    }
}

/// An audio file held in memory, read through `AudioFileOpenWithCallbacks` + `ExtAudioFile`
/// into Float32 non-interleaved buffers at the file's own rate and channel count.
final class MemoryAudioFile {
    private final class Box { let data: Data; init(_ d: Data) { data = d } }
    private let box: Unmanaged<Box>
    private var fileID: AudioFileID?
    private var ext: ExtAudioFileRef?
    let format: AVAudioFormat
    let length: AVAudioFramePosition

    init(data: Data, typeHint: String, name: URL) throws {
        box = Unmanaged.passRetained(Box(data))
        let hint: AudioFileTypeID = switch typeHint.lowercased() {
        case "m4a", "mp4": kAudioFileM4AType
        case "caf": kAudioFileCAFType
        case "wav": kAudioFileWAVEType
        case "aif", "aiff": kAudioFileAIFFType
        default: 0
        }
        let read: AudioFile_ReadProc = { ctx, position, count, buffer, actual in
            let d = Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue().data
            let start = Int(position)
            guard start <= d.count else { actual.pointee = 0; return kAudioFileEndOfFileError }
            let n = min(Int(count), d.count - start)
            d.withUnsafeBytes { src in buffer.copyMemory(from: src.baseAddress! + start, byteCount: n) }
            actual.pointee = UInt32(n)
            return noErr
        }
        let size: AudioFile_GetSizeProc = { ctx in Int64(Unmanaged<Box>.fromOpaque(ctx).takeUnretainedValue().data.count) }
        var status = AudioFileOpenWithCallbacks(box.toOpaque(), read, nil, size, nil, hint, &fileID)
        guard status == noErr, let fileID else {
            box.release()
            throw AudioLoaderError.unreadable(name, "AudioFileOpenWithCallbacks \(status)")
        }
        status = ExtAudioFileWrapAudioFileID(fileID, false, &ext)
        guard status == noErr, let ext else {
            AudioFileClose(fileID); box.release()
            throw AudioLoaderError.unreadable(name, "ExtAudioFileWrapAudioFileID \(status)")
        }
        var fileFormat = AudioStreamBasicDescription()
        var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileDataFormat, &propSize, &fileFormat)
        var frames: Int64 = 0
        propSize = UInt32(MemoryLayout<Int64>.size)
        ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileLengthFrames, &propSize, &frames)
        guard let client = AVAudioFormat(standardFormatWithSampleRate: fileFormat.mSampleRate,
                                         channels: max(1, fileFormat.mChannelsPerFrame)) else {
            ExtAudioFileDispose(ext); AudioFileClose(fileID); box.release()
            throw AudioLoaderError.unreadable(name, "unsupported format")
        }
        var asbd = client.streamDescription.pointee
        status = ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &asbd)
        guard status == noErr else {
            ExtAudioFileDispose(ext); AudioFileClose(fileID); box.release()
            throw AudioLoaderError.unreadable(name, "client format \(status)")
        }
        format = client
        length = frames
    }

    func read(into buf: AVAudioPCMBuffer) throws {
        guard let ext else { buf.frameLength = 0; return }
        var frames = buf.frameCapacity
        let abl = buf.mutableAudioBufferList
        let n = Int(abl.pointee.mNumberBuffers)
        let list = UnsafeMutableAudioBufferListPointer(abl)
        for i in 0..<n { list[i].mDataByteSize = frames * UInt32(MemoryLayout<Float>.size) }
        let status = ExtAudioFileRead(ext, &frames, abl)
        guard status == noErr else { throw AudioLoaderError.unreadable(URL(fileURLWithPath: "memory"), "ExtAudioFileRead \(status)") }
        buf.frameLength = frames
    }

    func close() {
        if let ext { ExtAudioFileDispose(ext) }
        if let fileID { AudioFileClose(fileID) }
        ext = nil; fileID = nil
        box.release()
    }
}
