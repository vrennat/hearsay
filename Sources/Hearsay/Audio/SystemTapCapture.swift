import AVFoundation
import CoreAudio
import HearsayCore

/// System audio through a Core Audio process tap (global, excluding our own process) wrapped in a
/// private aggregate device whose IOProc delivers the buffers. The tap only yields audio while some app
/// plays; `CAFStreamWriter` fills the gaps so one `startOffset` keeps the track aligned.
/// Rebuilds on default-output changes and can be paused for a call app (see `CallAppMonitor`).
/// Main-thread API; buffers arrive on `ioQueue`.
final class SystemTapCapture {
    private let log = HSLog("tap")
    private let url: URL
    private let meetingStart: UInt64
    private let generation = RestartGeneration()
    private let ioQueue = DispatchQueue(label: "com.tannervass.hearsay.tap-io", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var removeOutputListener: (() -> Void)?
    private(set) var writer: CAFStreamWriter?
    private(set) var isRunning = false
    private var stopped = false
    var onBuffer: (@Sendable (Float, Double) -> Void)?
    /// Every buffer and its host time, on the IO queue (the live transcript). The buffer does not own
    /// its memory: copy before returning.
    var onPCM: (@Sendable (AVAudioPCMBuffer, UInt64) -> Void)?
    /// Set by the session; while paused every buffer is dropped.
    var gate: PauseGate?

    init(url: URL, meetingStartHostTime: UInt64) {
        self.url = url
        self.meetingStart = meetingStartHostTime
    }

    func start() throws {
        stopped = false
        try build()
        removeOutputListener = CA.listen(CA.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.restart(reason: "default output device changed", after: 0.5)
        }
    }

    /// Stops the tap without finishing the file, and invalidates any pending rebuild.
    func pause(reason: String) -> RestartGeneration.Token {
        let token = generation.begin()
        log.info("Pausing tap: \(reason)")
        teardown()
        return token
    }

    /// Rebuilds after `delay` unless a newer chain or `stop()` started meanwhile.
    func resume(_ token: RestartGeneration.Token, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.retry(token, attempt: 1) }
    }

    func restart(reason: String, after delay: TimeInterval) {
        guard !stopped else { return }
        resume(pause(reason: reason), after: delay)
    }

    func isCurrent(_ token: RestartGeneration.Token) -> Bool { generation.isCurrent(token) && !stopped }

    private func retry(_ token: RestartGeneration.Token, attempt: Int) {
        guard isCurrent(token) else { return }
        do {
            try build()
            log.info("Tap rebuilt (attempt \(attempt))")
        } catch {
            log.error("Tap rebuild attempt \(attempt) failed: \(error)")
            teardown()
            DispatchQueue.main.asyncAfter(deadline: .now() + min(5.0, Double(attempt))) { [weak self] in
                self?.retry(token, attempt: attempt + 1)
            }
        }
    }

    func stop() -> AudioStream? {
        stopped = true
        generation.cancel()
        removeOutputListener?()
        removeOutputListener = nil
        teardown()
        // Let an in-flight IOProc block finish before closing the file.
        ioQueue.sync {}
        return writer?.finish()
    }

    private func build() throws {
        var exclude: [AudioObjectID] = []
        if let me = CA.processObject(pid: getpid()) { exclude.append(me) }
        var description: CATapDescription!
        try tryObjC("create tap description") {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
            description.uuid = UUID()
            description.isPrivate = true
            description.muteBehavior = .unmuted
            description.name = "Hearsay system audio"
        }
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status: OSStatus = noErr
        try tryObjC("create process tap") { status = AudioHardwareCreateProcessTap(description, &tap) }
        try check(status, "AudioHardwareCreateProcessTap (System Audio Recording permission?)")
        tapID = tap

        let asbd = try CA.get(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
        var asbdCopy = asbd
        guard let tapFormat = AVAudioFormat(streamDescription: &asbdCopy) else {
            throw OSStatusError(status: -1, what: "tap format")
        }

        let output = try CA.defaultOutputDevice()
        guard let outputUID = CA.deviceUID(output) else { throw OSStatusError(status: -1, what: "output device UID") }
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Hearsay Tap",
            kAudioAggregateDeviceUIDKey: "com.tannervass.hearsay.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &agg), "AudioHardwareCreateAggregateDevice")
        aggregateID = agg

        if writer == nil {
            writer = try CAFStreamWriter(kind: .system, url: url, sampleRate: tapFormat.sampleRate,
                                         channels: Int(tapFormat.channelCount), meetingStartHostTime: meetingStart)
            log.info("Tap format \(tapFormat.sampleRate) Hz x \(tapFormat.channelCount), interleaved \(tapFormat.isInterleaved)")
        }
        let writer = self.writer!
        let onBuffer = self.onBuffer
        let onPCM = self.onPCM
        let gate = self.gate
        // The aggregate's input buffer list holds the output device's own input streams first, then
        // the tap. On an interface with inputs (a MOTU M4: one 4-channel buffer ahead of the tap's
        // stereo one) the whole list is not a stereo buffer, so pick the tap's by position.
        let skip = (try? CA.array(output, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, of: AudioObjectID.self).count) ?? 0
        let tapChannels = UInt32(tapFormat.channelCount)
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, ioQueue) { _, inData, inTime, _, _ in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard list.count > skip, list[skip].mNumberChannels == tapChannels else { return }
            var single = AudioBufferList(mNumberBuffers: 1, mBuffers: list[skip])
            guard let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: &single, deallocator: nil),
                  buffer.frameLength > 0 else { return }
            let t = inTime.pointee
            let raw = t.mFlags.contains(.hostTimeValid) ? t.mHostTime : HostClock.now()
            if gate?.drops(raw) == true { return }
            let host = gate?.shift(raw) ?? raw  // recording clock: pauses cut out
            let db = writer.append(buffer, hostTime: host)
            onBuffer?(db, HostClock.seconds(raw))
            onPCM?(buffer, host)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        procID = proc
        try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
        isRunning = true
        log.info("Tap running on output \(outputUID); \(skip) input stream(s) ahead of the tap")
    }

    private func teardown() {
        isRunning = false
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}
