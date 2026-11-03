import AVFoundation
import CoreAudio
import HearsayCore
import os

/// System audio through a Core Audio process tap (global, excluding our own process) wrapped in a
/// private aggregate device whose IOProc delivers the buffers. The tap only yields audio while some app
/// plays; `CAFStreamWriter` fills the gaps so one `startOffset` keeps the track aligned.
/// Rebuilds on default-output and output sample-rate changes and can be paused for a call app (see
/// `CallAppMonitor`); every rebuild waits for the output device to settle (`OutputSettle`).
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
    /// Listeners on the output device the tap was last built on; kept through pauses so a rebuild
    /// can tell whether the device is still changing.
    private var removeDeviceListeners: (() -> Void)?
    private var watchedOutput = AudioObjectID(kAudioObjectUnknown)
    private var builtRate: Double = 0
    /// Last default-output or output-device change, in `systemUptime` seconds (main thread).
    private var lastOutputChange: Double?
    /// Which build's IOProc may write. A teardown whose stop or destroy fails (as Bluetooth
    /// reconfiguration can make it) would otherwise leave a second IOProc writing into the same file.
    private let io = OSAllocatedUnfairLock(initialState: IOState())
    private struct IOState { var epoch = 0; var tornDownAt: UInt64 = 0; var orphanCallbacks = 0; var unmatchedLogged = false }
    /// A rate check is pending (`checkRate`), so a burst of rate changes schedules one.
    private var rateCheckPending = false
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
            guard let self else { return }
            self.outputChanged()
            // Watch the new device now, so the settle wait sees its own profile switch.
            if let output = try? CA.defaultOutputDevice() { self.watch(output) }
            self.restart(reason: "default output device changed", after: 0.5)
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

    private func retry(_ token: RestartGeneration.Token, attempt: Int, waitingSince: Double? = nil) {
        guard isCurrent(token) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let since = waitingSince ?? now
        let wait = OutputSettle.wait(now: now, lastChange: lastOutputChange, waitingSince: since)
        if wait > 0 {
            if waitingSince == nil { log.info("Waiting for the output device to settle before rebuilding the tap") }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.retry(token, attempt: attempt, waitingSince: since)
            }
            return
        }
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
        removeDeviceListeners?()
        removeDeviceListeners = nil
        watchedOutput = AudioObjectID(kAudioObjectUnknown)
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
        watch(output)
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
            log.info("System file format \(tapFormat.sampleRate) Hz x \(tapFormat.channelCount), interleaved \(tapFormat.isInterleaved)")
        }
        let rate = (try? CA.get(agg, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))) ?? 0
        builtRate = (try? CA.get(output, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))) ?? 0
        log.info("Tap format \(tapFormat.sampleRate) Hz x \(tapFormat.channelCount); aggregate \(rate) Hz, output \(builtRate) Hz")
        if rate > 0, rate != tapFormat.sampleRate {
            log.error("Tap format \(tapFormat.sampleRate) Hz differs from the aggregate's \(rate) Hz; buffers may be mislabelled")
        }
        let writer = self.writer!
        let io = self.io
        let (epoch, orphans) = io.withLock { s -> (Int, Int) in
            defer { s.orphanCallbacks = 0; s.unmatchedLogged = false }
            s.epoch += 1
            return (s.epoch, s.orphanCallbacks)
        }
        if orphans > 0 { log.error("Dropped \(orphans) callback(s) from an earlier tap that kept running") }
        let log = self.log
        let onBuffer = self.onBuffer
        let onPCM = self.onPCM
        let gate = self.gate
        // The aggregate's input buffer list holds the output device's own input streams first, then
        // the tap. On an interface with inputs (a MOTU M4: one 4-channel buffer ahead of the tap's
        // stereo one) the whole list is not a stereo buffer, so pick the tap's by position.
        let skip = (try? CA.array(output, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, of: AudioObjectID.self).count) ?? 0
        let tapChannels = UInt32(tapFormat.channelCount)
        var proc: AudioDeviceIOProcID?
        let lateTicks = UInt64(0.1 / HostClock.seconds(1_000_000) * 1_000_000)
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, ioQueue) { _, inData, inTime, _, _ in
            let t = inTime.pointee
            let raw = t.mFlags.contains(.hostTimeValid) ? t.mHostTime : HostClock.now()
            let current = io.withLock { s -> Bool in
                guard s.epoch == epoch else {
                    // Blocks already queued at teardown are normal; one captured 100 ms after it is a survivor.
                    if raw > s.tornDownAt + lateTicks { s.orphanCallbacks += 1 }
                    return false
                }
                return true
            }
            guard current else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            // The device's input streams can change after the build (a headset entering call mode),
            // so if the tap is not at `skip`, take the last buffer of the tap's width: taps follow
            // the device's own inputs.
            let index = list.count == skip + 1 && list[skip].mNumberChannels == tapChannels ? skip
                : list.indices.last(where: { list[$0].mNumberChannels == tapChannels })
            guard let index else {
                let first = io.withLock { s -> Bool in defer { s.unmatchedLogged = true }; return !s.unmatchedLogged }
                if first { log.error("No \(tapChannels)-channel tap buffer among \(list.count) input buffer(s); dropping until rebuilt") }
                return
            }
            var single = AudioBufferList(mNumberBuffers: 1, mBuffers: list[index])
            guard let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: &single, deallocator: nil),
                  buffer.frameLength > 0 else { return }
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
        let now = HostClock.now()
        io.withLock { $0.epoch += 1; $0.tornDownAt = now }  // an IOProc that survives the calls below writes nothing more
        func note(_ status: OSStatus, _ what: String) {
            if status != noErr { log.error("\(OSStatusError(status: status, what: what))") }
        }
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                note(AudioDeviceStop(aggregateID, procID), "AudioDeviceStop")
                note(AudioDeviceDestroyIOProcID(aggregateID, procID), "AudioDeviceDestroyIOProcID")
            }
            note(AudioHardwareDestroyAggregateDevice(aggregateID), "AudioHardwareDestroyAggregateDevice")
        }
        if tapID != kAudioObjectUnknown { note(AudioHardwareDestroyProcessTap(tapID), "AudioHardwareDestroyProcessTap") }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func outputChanged() { lastOutputChange = ProcessInfo.processInfo.systemUptime }

    /// Watches the output device the tap is built on. Any stream or rate change counts against the
    /// settle wait. A rate change also schedules `checkRate`: the tap's format was read at build, and
    /// AirPods switching between music and call mode change rate without the default output changing.
    private func watch(_ output: AudioObjectID) {
        guard output != watchedOutput else { return }
        removeDeviceListeners?()
        watchedOutput = output
        let rate = CA.listen(output, kAudioDevicePropertyNominalSampleRate) { [weak self] in
            guard let self else { return }
            self.outputChanged()
            if !self.rateCheckPending { self.rateCheckPending = true; self.checkRate(output, since: ProcessInfo.processInfo.systemUptime) }
        }
        let streams = CA.listen(output, kAudioDevicePropertyStreams) { [weak self] in self?.outputChanged() }
        removeDeviceListeners = { rate(); streams() }
    }

    /// Rebuilds for a rate change only once the device has settled and only if the running tap's rate
    /// really differs from the one it was built at. Tearing down mid-change is what silenced the output
    /// (2026-11-02), so the running tap is left alone until then.
    private func checkRate(_ output: AudioObjectID, since: Double) {
        let wait = OutputSettle.wait(now: ProcessInfo.processInfo.systemUptime, lastChange: lastOutputChange, waitingSince: since)
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.checkRate(output, since: since) }
            return
        }
        rateCheckPending = false
        let now = (try? CA.get(output, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))) ?? 0
        guard isRunning, output == watchedOutput, now > 0, now != builtRate else { return }
        restart(reason: "output sample rate changed \(builtRate) -> \(now) Hz", after: 0)
    }
}
