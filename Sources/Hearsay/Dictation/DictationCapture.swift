@preconcurrency import AVFoundation
import Foundation
import HearsayCore

/// The dictation microphone: its own `AVAudioEngine`, opened only while dictation is active and never
/// shared with a meeting's `MicCapture`. Delivers 16 kHz mono chunks and keeps the whole clip.
final class DictationCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var clip: [Float] = []
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// `onChunk` runs on the audio thread with each converted chunk.
    func start(onChunk: @escaping @Sendable ([Float]) -> Void) throws {
        lock.lock(); clip.removeAll(keepingCapacity: true); lock.unlock()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationError.noInput }
        // Fold to the active channels first (an interface's dead inputs would cost 12 dB in a plain
        // downmix, see ChannelFold), then resample the mono result.
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false) else { throw DictationError.noInput }
        converter = AVAudioConverter(from: mono, to: target)
        try tryObjC("dictation tap") {
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard let self, let folded = ChannelFold.mono(buffer), let samples = self.convert(folded), !samples.isEmpty else { return }
                self.lock.lock(); self.clip += samples; self.lock.unlock()
                onChunk(samples)
            }
        }
        engine.prepare()
        try tryObjC("dictation engine start") { try self.engine.start() }
        guard engine.isRunning else {
            input.removeTap(onBus: 0)
            throw DictationError.engineDidNotStart
        }
    }

    /// Stops the microphone and returns the whole clip.
    func stop() -> [Float] {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        lock.lock(); defer { lock.unlock() }
        let out = clip
        clip = []
        return out
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let ch = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }
}

enum DictationError: Error, CustomStringConvertible {
    case noInput, engineDidNotStart, micDenied
    var description: String {
        switch self {
        case .noInput: return "no microphone input"
        case .engineDidNotStart: return "the microphone did not start"
        case .micDenied: return "microphone access is off for Hearsay"
        }
    }
}
