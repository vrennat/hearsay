import AVFoundation
import HearsayCore

/// Mic through AVAudioEngine with voice processing OFF (it stops Zoom and Meet hearing the user and
/// turns call audio down; echo is removed from the transcript instead). Rebuilds itself on device
/// changes; `RestartGeneration` makes an older rebuild chain stop when a newer one or `stop()` begins.
/// Main-thread API; buffers arrive on the engine's tap thread.
final class MicCapture {
    private let log = HSLog("mic")
    private let url: URL
    private let meetingStart: UInt64
    private let generation = RestartGeneration()
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private(set) var writer: CAFStreamWriter?
    private var stopped = false
    /// Called on the tap thread with (dBFS, host seconds).
    var onBuffer: (@Sendable (Float, Double) -> Void)?
    /// Every buffer and its host time, on the audio thread (the live transcript).
    var onPCM: (@Sendable (AVAudioPCMBuffer, UInt64) -> Void)?

    init(url: URL, meetingStartHostTime: UInt64) {
        self.url = url
        self.meetingStart = meetingStartHostTime
    }

    func start() throws {
        stopped = false
        try build()
    }

    /// Tears the engine down and rebuilds it (device change, silent-mic retry).
    func restart(reason: String) {
        guard !stopped else { return }
        let token = generation.begin()
        log.info("Rebuilding mic engine: \(reason)")
        teardown()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.retry(token, attempt: 1) }
    }

    private func retry(_ token: RestartGeneration.Token, attempt: Int) {
        guard generation.isCurrent(token), !stopped else { return }
        do {
            try build()
            log.info("Mic engine rebuilt (attempt \(attempt))")
        } catch {
            log.error("Mic rebuild attempt \(attempt) failed: \(error)")
            teardown()
            let delay = min(5.0, Double(attempt))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.retry(token, attempt: attempt + 1) }
        }
    }

    func stop() -> AudioStream? {
        stopped = true
        generation.cancel()
        teardown()
        return writer?.finish()
    }

    private func build() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try tryObjC("disable voice processing") {
            if input.isVoiceProcessingEnabled { try input.setVoiceProcessingEnabled(false) }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw ObjCException(description: "mic input has no format (no input device, or microphone access denied)")
        }
        if writer == nil {
            writer = try CAFStreamWriter(kind: .mic, url: url, sampleRate: format.sampleRate,
                                         channels: Int(format.channelCount), meetingStartHostTime: meetingStart)
            log.info("Mic format \(format.sampleRate) Hz x \(format.channelCount)")
        }
        let writer = self.writer!
        let onBuffer = self.onBuffer
        let onPCM = self.onPCM
        let channelLog = ChannelLog(channels: Int(format.channelCount), frames: Int(format.sampleRate * 2), log: log)
        try tryObjC("install mic tap") {
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
                let host = when.isHostTimeValid ? when.hostTime : HostClock.now()
                channelLog.observe(buffer)
                let db = writer.append(buffer, hostTime: host)
                onBuffer?(db, HostClock.seconds(host))
                onPCM?(buffer, host)
            }
        }
        engine.prepare()
        try tryObjC("start engine") { try engine.start() }
        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.restart(reason: "audio configuration changed") }
    }

    private func teardown() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        guard let engine else { return }
        try? tryObjC("stop engine") {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        self.engine = nil
    }
}

/// Logs each input channel's level over the first two seconds of a tap, once, so a device whose mic
/// sits on one of several inputs (a 4-input MOTU) is visible in the log without opening the file.
final class ChannelLog: @unchecked Sendable {
    private let channels: Int
    private let target: Int
    private let log: HSLog
    private var power: [Float]
    private var seen = 0
    private var done = false

    init(channels: Int, frames: Int, log: HSLog) {
        self.channels = channels; self.target = frames; self.log = log
        power = Array(repeating: 0, count: channels)
    }

    /// Audio thread. Accumulates mean square per channel until `target` frames, then logs.
    func observe(_ buffer: AVAudioPCMBuffer) {
        guard !done, let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        for c in 0..<min(channels, Int(buffer.format.channelCount)) {
            var sum: Float = 0
            let ch = data[c]
            for i in 0..<n { sum += ch[i] * ch[i] }
            power[c] += sum
        }
        seen += n
        guard seen >= target else { return }
        done = true
        let levels = power.map { $0 > 0 ? max(-120, 10 * log10($0 / Float(seen))) : -120 }
        let floorPower = powf(10, ChannelFold.activeFloorDBFS / 10) * Float(seen)
        let active = power.enumerated().filter { $0.element > floorPower }.map(\.offset)
        let text = levels.enumerated().map { String(format: "ch%d %.0f", $0.offset, $0.element) }.joined(separator: ", ")
        let secs = String(format: "%.1f", Double(seen) / buffer.format.sampleRate)
        log.info("Mic channels over \(secs) s: \(text) dBFS; active \(active)")
    }
}
