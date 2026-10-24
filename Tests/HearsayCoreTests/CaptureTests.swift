import AVFoundation
import Foundation
import Testing
@testable import HearsayCore

@Suite struct CaptureTests {
    // MARK: startOffset and gap fill

    @Test func firstBufferSetsStartOffset() {
        var t = StreamTimeline(sampleRate: 48_000)
        #expect(t.silenceBefore(bufferAt: 2.25, frames: 480) == 0)
        #expect(t.startOffset == 2.25)
        #expect(t.framesWritten == 480)
    }

    @Test func bufferBeforeMeetingStartClampsToZero() {
        var t = StreamTimeline(sampleRate: 16_000)
        _ = t.silenceBefore(bufferAt: -0.01, frames: 160)
        #expect(t.startOffset == 0)
    }

    @Test func contiguousBuffersNeedNoSilence() {
        var t = StreamTimeline(sampleRate: 48_000)
        _ = t.silenceBefore(bufferAt: 1.0, frames: 4800)
        // 0.1 s later plus 10 ms jitter: within tolerance
        #expect(t.silenceBefore(bufferAt: 1.11, frames: 4800) == 0)
        #expect(t.framesWritten == 9600)
    }

    @Test func gapIsFilledSoFramesStayOnMeetingTime() {
        var t = StreamTimeline(sampleRate: 48_000)
        _ = t.silenceBefore(bufferAt: 1.0, frames: 4800)  // covers 1.0 ..< 1.1
        let pad = t.silenceBefore(bufferAt: 3.1, frames: 4800)  // 2 s silent gap
        #expect(pad == 96_000)
        #expect(t.framesWritten == 4800 + 96_000 + 4800)
        // the frame at meeting time 3.1 sits at file index (3.1 - startOffset) * rate
        #expect(Double(t.framesWritten - 4800) / 48_000 + 1.0 == 3.1)
    }

    @Test func hostClockSignedSeconds() {
        let a = HostClock.now()
        #expect(HostClock.seconds(from: a, to: a) == 0)
        #expect(HostClock.seconds(from: a + 1_000_000, to: a) < 0)
    }

    // MARK: Generation counter

    @Test func newerGenerationCancelsOlderChain() {
        let g = RestartGeneration()
        let first = g.begin()
        #expect(g.isCurrent(first))
        let second = g.begin()
        #expect(!g.isCurrent(first))
        #expect(g.isCurrent(second))
        g.cancel()  // stop()
        #expect(!g.isCurrent(second))
    }

    // MARK: Call-app policy

    @Test func ignoredBundlesMatchLowercased() {
        #expect(CallAppPolicy.isIgnored(bundleID: "com.apple.CoreSpeech", pid: 10, ownPID: 1))
        #expect(CallAppPolicy.isIgnored(bundleID: "COM.APPLE.CORESPEECH", pid: 10, ownPID: 1))
        #expect(!CallAppPolicy.isIgnored(bundleID: "us.zoom.xos", pid: 10, ownPID: 1))
        #expect(!CallAppPolicy.isIgnored(bundleID: nil, pid: 10, ownPID: 1))
        #expect(CallAppPolicy.isIgnored(bundleID: "us.zoom.xos", pid: 7, ownPID: 7))  // our own pid
    }

    @Test func onlyNewNonIgnoredInputUsersPause() {
        let now: [(pid: Int32, bundleID: String?)] = [
            (5, "us.zoom.xos"), (6, "com.apple.corespeech"), (7, "com.tannervass.hearsay"), (8, "com.google.Chrome"),
        ]
        #expect(CallAppPolicy.newInputUsers(previous: [5], current: now, ownPID: 7) == [8])
    }

    // MARK: Level

    @Test func levelTracksLoudBuffersAndGoesQuietAfterGap() {
        var l = AudioLevel()
        l.record(dBFS: -63, at: 10)
        #expect(l.lastLoudAt == nil)  // quiet headset mic is not "heard"
        l.record(dBFS: -40, at: 11)
        #expect(l.lastLoudAt == 11)
        #expect(l.displayLevel(now: 11.2) == -40)
        #expect(l.displayLevel(now: 11.31) == AudioLevel.floor)
    }

    @Test func dBFSOfFullScaleSquareIsZero() {
        let samples = [Float](repeating: 1, count: 100)
        samples.withUnsafeBufferPointer { p in
            #expect(abs(AudioLevel.dBFS(channels: [p.baseAddress!], frames: 100)) < 0.001)
        }
        let zeros = [Float](repeating: 0, count: 100)
        zeros.withUnsafeBufferPointer { p in
            #expect(AudioLevel.dBFS(channels: [p.baseAddress!], frames: 100) == AudioLevel.floor)
        }
    }

    // MARK: Launch options

    @Test func parsesTestInstanceArgs() {
        let o = LaunchOptions.parse(["--record-for", "5", "-NSFoo", "YES", "--root", "/tmp/x", "--after-crash"])
        #expect(o.recordFor == 5)
        #expect(o.root?.path == "/tmp/x")
        #expect(o.afterCrash)
        #expect(!o.resumeRecording)
        #expect(o.isTestInstance)
        #expect(!LaunchOptions.parse([]).isTestInstance)
    }

    // MARK: Lifecycle and recovery

    @Test func beginWritesRecordingAndFinishWritesRecorded() throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let m = try RecordingLifecycle.begin(store: store, startedAt: TestSupport.date("2026-10-23T09:30:00.000Z"))
        #expect(try store.loadMeeting(m.id).status == .recording)
        #expect(FileManager.default.fileExists(atPath: store.folder(m.id).appendingPathComponent("audio").path))
        let streams = [AudioStream(kind: .system, file: "audio/system.caf", startOffset: 3.5, sampleRate: 48_000, channels: 2),
                       AudioStream(kind: .mic, file: "audio/mic.caf", startOffset: 0.1, sampleRate: 48_000, channels: 1)]
        _ = try RecordingLifecycle.finish(m, store: store, endedAt: m.startedAt.addingTimeInterval(60), streams: streams)
        let done = try store.loadMeeting(m.id)
        #expect(done.status == .recorded)
        #expect(done.duration == 60)
        #expect(done.streams.map(\.kind) == [.mic, .system])
        #expect(done.streams[1].startOffset == 3.5)
    }

    @Test func recoveryMarksRecordingMeetingsInterrupted() throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let start = TestSupport.date("2026-10-23T09:30:00.000Z")
        let crashed = try RecordingLifecycle.begin(store: store, startedAt: start, title: "Crashed")
        let live = try RecordingLifecycle.begin(store: store, startedAt: start, title: "Live")
        // the crashed meeting's mic writer got a buffer before the crash
        let writer = try CAFStreamWriter(kind: .mic, url: store.folder(crashed.id).appendingPathComponent("audio/mic.caf"),
                                         sampleRate: 16_000, channels: 1, meetingStartHostTime: HostClock.now())
        writer.append(Self.tone(frames: 1600, rate: 16_000), hostTime: HostClock.now())
        // no finish(): simulates the crash; the file is still open

        let ids = RecordingLifecycle.recoverInterrupted(store: store, skip: [live.id])
        #expect(ids == [crashed.id])
        let m = try store.loadMeeting(crashed.id)
        #expect(m.status == .recorded)
        #expect(m.error == "interrupted")
        #expect(m.endedAt != nil)
        #expect(m.streams.count == 1)
        #expect(m.streams[0].sampleRate == 16_000)
        #expect(try store.loadMeeting(live.id).status == .recording)
        _ = writer.finish()
    }

    // MARK: CAF writer

    @Test func writerRecordsOffsetPadsGapsAndSurvivesUnclosedFile() throws {
        let root = try TestSupport.tempRoot()
        let url = root.appendingPathComponent("audio/system.caf")
        let rate = 48_000.0
        let start = HostClock.now()
        let ticksPerSecond = UInt64(1 / HostClock.seconds(1_000_000) * 1_000_000)
        let w = try CAFStreamWriter(kind: .system, url: url, sampleRate: rate, channels: 2, meetingStartHostTime: start)
        let b = Self.tone(frames: 4800, rate: rate, channels: 2)
        w.append(b, hostTime: start + 2 * ticksPerSecond)  // first buffer at 2 s
        w.append(b, hostTime: start + 3 * ticksPerSecond)  // 0.9 s gap
        #expect(abs((w.startOffset ?? -1) - 2) < 0.001)
        #expect(FileManager.default.fileExists(atPath: CAFStreamWriter.sidecarURL(for: url).path))

        // Crash safety: a copy taken while the writer is still open must be readable.
        let copy = root.appendingPathComponent("copy.caf")
        try FileManager.default.copyItem(at: url, to: copy)
        let partial = try AVAudioFile(forReading: copy)
        #expect(partial.length > 0)

        let stream = try #require(w.finish())
        #expect(stream.sampleRate == rate)
        #expect(stream.channels == 2)
        #expect(!FileManager.default.fileExists(atPath: CAFStreamWriter.sidecarURL(for: url).path))
        let f = try AVAudioFile(forReading: url)
        #expect(abs(Double(f.length) - 1.1 * rate) < 2)  // 0.1 + 0.9 silence + 0.1
    }

    @Test func writerConvertsALaterDeviceFormat() throws {
        let root = try TestSupport.tempRoot()
        let url = root.appendingPathComponent("audio/mic.caf")
        let start = HostClock.now()
        let w = try CAFStreamWriter(kind: .mic, url: url, sampleRate: 48_000, channels: 1, meetingStartHostTime: start)
        w.append(Self.tone(frames: 4800, rate: 48_000), hostTime: start)
        w.append(Self.tone(frames: 2400, rate: 24_000), hostTime: HostClock.now())  // rebuilt on a 24 kHz headset
        _ = w.finish()
        let f = try AVAudioFile(forReading: url)
        #expect(f.fileFormat.sampleRate == 48_000)
        #expect(f.length >= 9000)
    }

    @Test func writerAcceptsAFourChannelInterface() throws {
        // A MOTU M4 reports 4 mic inputs; AVAudioFormat's plain initializer returns nil above 2 channels.
        let root = try TestSupport.tempRoot()
        let url = root.appendingPathComponent("audio/mic.caf")
        let start = HostClock.now()
        let w = try CAFStreamWriter(kind: .mic, url: url, sampleRate: 48_000, channels: 4, meetingStartHostTime: start)
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4))
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
        let b = try #require(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4800))
        b.frameLength = 4800
        for c in 0..<4 { for i in 0..<4800 { b.floatChannelData![c][i] = sinf(Float(i) * 0.05) * 0.5 } }
        w.append(b, hostTime: start)
        let stream = try #require(w.finish())
        #expect(stream.channels == 4)
        let f = try AVAudioFile(forReading: url)
        #expect(f.fileFormat.channelCount == 4)
        #expect(f.length == 4800)
    }

    @Test func streamWithNoBuffersLeavesNoFile() throws {
        let url = try TestSupport.tempRoot().appendingPathComponent("audio/system.caf")
        let w = try CAFStreamWriter(kind: .system, url: url, sampleRate: 48_000, channels: 2, meetingStartHostTime: HostClock.now())
        #expect(w.finish() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Lock and placeholder process

    @Test func lockReportsLiveHolderOnly() throws {
        let lock = RecordingLock(url: try TestSupport.tempRoot().appendingPathComponent("recording.pid"))
        #expect(!lock.isHeld)
        lock.acquire()
        #expect(lock.isHeld)
        lock.release(pid: 1)  // not ours: kept
        #expect(lock.isHeld)
        lock.release()
        #expect(!lock.isHeld)
    }

    /// An interrupted recording with nothing captured ends `failed`, and the error still says interrupted.
    /// (The success path keeping `error == "interrupted"` needs Parakeet; it is checked by the e2e script.)
    @Test func interruptedWithNoAudioFailsAndStaysMarkedInterrupted() async throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let m = try RecordingLifecycle.begin(store: store, startedAt: Date())
        _ = try RecordingLifecycle.finish(m, store: store, endedAt: Date(), streams: [], error: "interrupted")
        await #expect(throws: ProcessError.self) { try await ProcessPipeline.process(meetingID: m.id, store: store) }
        let after = try store.loadMeeting(m.id)
        #expect(after.status == .failed)
        #expect(after.error == "interrupted; no audio captured")
    }

    /// Missing, empty and too-quiet streams end `failed` with a clear error and never call the models.
    @Test func unusableStreamsFailClearly() async throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let m = try RecordingLifecycle.begin(store: store, startedAt: Date())
        let audio = store.folder(m.id).appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        // A quiet tone (about -60 dBFS) for 5 s: decodes fine, fails the loudness gate.
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let quiet = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 80_000)!
        quiet.frameLength = 80_000
        for i in 0..<80_000 { quiet.floatChannelData![0][i] = Float(sin(Double(i) * 0.06)) * 0.001 }
        let file = try AVAudioFile(forWriting: audio.appendingPathComponent("mic.caf"), settings: fmt.settings)
        try file.write(from: quiet)
        _ = try RecordingLifecycle.finish(m, store: store, endedAt: Date(), streams: [
            AudioStream(kind: .mic, file: "audio/mic.caf", startOffset: 0, sampleRate: 16_000, channels: 1),
            AudioStream(kind: .system, file: "audio/system.caf", startOffset: 1, sampleRate: 48_000, channels: 2),  // missing
        ], error: nil)
        await #expect(throws: ProcessError.self) { try await ProcessPipeline.process(meetingID: m.id, store: store) }
        let after = try store.loadMeeting(m.id)
        #expect(after.status == .failed)
        #expect(after.error?.hasPrefix("no speech") == true)
        #expect(try store.loadTranscript(m.id) == nil)
    }

    static func tone(frames: Int, rate: Double, channels: Int = 1) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                channels: AVAudioChannelCount(channels), interleaved: false)!
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for c in 0..<channels { for i in 0..<frames { b.floatChannelData![c][i] = Float(sin(Double(i) * 0.06)) * 0.3 } }
        return b
    }
}
