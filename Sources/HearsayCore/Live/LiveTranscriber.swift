@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// Live transcript while recording (spec, Live transcript): streaming Parakeet per stream plus an
/// LS-EEND live diarizer per stream, with per-window echo suppression and a writer that saves
/// `live.json` / `live.md` every 2 s and on every rename. Never touches `meeting.json`.
///
/// Engines load lazily on the first buffer of each stream and stay loaded for the life of the
/// instance; `begin` resets them for the next meeting. The app uses `LiveTranscriber.shared`, so the
/// models load once per process; `LiveTranscriber()` makes an independent instance with its own
/// engines (dictation, tests, `live-sim`).
public actor LiveTranscriber {
    public static let shared = LiveTranscriber()
    public static let saveInterval: TimeInterval = 2
    private static let log = HearsayCore.logger("live")
    static let sampleRate = 16_000.0
    static let frameSamples = Int(sampleRate * Loudness.frameSeconds)  // 160

    // MARK: Per-stream engines and state

    final class Engines {
        let asr: StreamingUnifiedAsrManager
        let diarizer: LSEENDDiarizer
        init(asr: StreamingUnifiedAsrManager, diarizer: LSEENDDiarizer) { self.asr = asr; self.diarizer = diarizer }
    }

    struct StreamState {
        /// Meeting time of the first sample fed; later buffers are placed relative to it.
        var origin: Double?
        var samplesFed = 0
        var words: [Word] = []
        var segments: [LiveLineBuilder.Segment] = []
        /// 10 ms dBFS curve from `origin`.
        var loudness: [Float] = []
        var pendingLoudness: [Float] = []
        var audioEnd: Double? { origin.map { $0 + Double(samplesFed) / LiveTranscriber.sampleRate } }
    }

    private var engines: [StreamKind: Engines] = [:]
    private var loading: [StreamKind: Task<Engines, Error>] = [:]
    private var streams: [StreamKind: StreamState] = [:]
    private var echo = LiveEchoTracker()
    private let echoMatcher: LiveEchoMatcher
    private let now: @Sendable () -> Date

    private var meetingID: String?
    private var store: MeetingStore?
    private var speakerNames: [String: String] = [:]
    private var lastDiagnostic: Date?
    private var lastSave: Date?
    private var dirty = false
    private var onLines: (@Sendable ([LiveLine]) -> Void)?

    /// LS-EEND model per stream: `ami` (meeting rooms), `callhome` (telephone), `dihard2`, `dihard3`.
    /// The call uses dihard3: on synthetic Zoom-like call tracks (Opus 20-24 kbps) it found 3 of 4
    /// voices where ami found 2 (similar voices, reverb, noise), split 4 distinct voices 62/32/32 s
    /// where ami gave 62/61/3, and matched ami on two voices. The room keeps ami (meeting-room audio).
    public var diarizerVariant: [StreamKind: String] = [.system: "dihard3"]

    public init(echoMatcher: @escaping LiveEchoMatcher = LiveEcho.match,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.echoMatcher = echoMatcher
        self.now = now
    }

    public func setDiarizerVariant(_ name: String, for kind: StreamKind) { diarizerVariant[kind] = name }

    static func variant(_ name: String?) -> ModelNames.LSEEND.Variant {
        switch name { case "callhome": .callhome; case "dihard2": .dihard2; case "dihard3": .dihard3; default: .ami }
    }

    // MARK: Session

    /// Starts a new live transcript for `meetingID` in `store` (nil store: nothing is written).
    /// Keeps loaded engines, clears everything else.
    public func begin(meetingID: String?, store: MeetingStore?, onLines: (@Sendable ([LiveLine]) -> Void)? = nil) async {
        for e in engines.values {
            try? await e.asr.reset()
            e.diarizer.reset()
        }
        self.meetingID = meetingID; self.store = store; self.onLines = onLines
        streams = [:]; echo = LiveEchoTracker(); speakerNames = [:]
        lastDiagnostic = nil; lastSave = nil; dirty = false
    }

    /// Loads both streams' engines now instead of on the first buffer.
    public func preload() async throws {
        _ = try await engine(.mic)
        _ = try await engine(.system)
    }

    /// Appends 16 kHz mono samples whose first sample is at `offset` seconds of meeting time.
    /// A gap since the previous buffer is filled with silence so timings stay on the meeting clock.
    public func append(_ samples: [Float], at offset: Double, stream: StreamKind) async throws {
        guard !samples.isEmpty else { return }
        let e = try await engine(stream)
        var st = streams[stream] ?? StreamState()
        var input = samples
        if st.origin == nil { st.origin = offset }
        if let end = st.audioEnd {
            let gap = Int(((offset - end) * Self.sampleRate).rounded())
            if gap > 0 { input = [Float](repeating: 0, count: gap) + input }
        }
        let origin = st.origin!

        // Loudness for the echo filter, in whole 10 ms frames.
        st.pendingLoudness += input
        let frames = st.pendingLoudness.count / Self.frameSamples
        if frames > 0 {
            let n = frames * Self.frameSamples
            st.loudness += Loudness.curve(Array(st.pendingLoudness[0..<n]))
            st.pendingLoudness.removeFirst(n)
        }

        // Streaming Parakeet. Word times are seconds from the stream's first sample.
        try await e.asr.appendAudio(Self.pcmBuffer(input))
        try await e.asr.processBufferedAudio()
        Self.appendTokens(await e.asr.consumeTokenTimings(), origin: origin, to: &st.words)

        // LS-EEND has no lock; every call to it runs inside this actor, which serializes them.
        try e.diarizer.addAudio(input, sourceSampleRate: Self.sampleRate)
        _ = try e.diarizer.process()
        st.segments = Self.segments(e.diarizer, origin: origin)

        st.samplesFed += input.count
        streams[stream] = st
        applyEcho()
        dirty = true
        try saveIfDue()
    }

    /// Flushes both streams and saves. The engines stay loaded for the next `begin`.
    @discardableResult
    public func finish() async throws -> LiveTranscript {
        for (kind, e) in engines {
            guard var st = streams[kind], let origin = st.origin else { continue }
            _ = try await e.asr.finish()
            Self.appendTokens(await e.asr.consumeTokenTimings(), origin: origin, to: &st.words)
            _ = try? e.diarizer.finalizeSession()
            st.segments = Self.segments(e.diarizer, origin: origin)
            streams[kind] = st
        }
        dirty = true
        try save()
        return snapshot()
    }

    // MARK: Names

    /// Names a live speaker (nil or empty clears it) and saves immediately.
    public func renameSpeaker(_ id: String, to name: String?) throws {
        guard !LiveLineBuilder.isUncertain(id) else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        speakerNames[id] = trimmed.isEmpty ? nil : trimmed
        dirty = true
        try save()
    }

    public var names: [String: String] { speakerNames }

    // MARK: Output

    public func snapshot() -> LiveTranscript {
        var lines: [LiveLine] = []
        let kept = echoFiltered()
        for (kind, st) in streams {
            lines += LiveLineBuilder.lines(stream: kind, words: kept[kind] ?? [], segments: st.segments)
        }
        lines.sort { $0.start != $1.start ? $0.start < $1.start : $0.speaker < $1.speaker }
        return LiveTranscript(updatedAt: now(), speakerNames: speakerNames, lines: lines)
    }

    /// Live speakers seen so far (ids sorted), for the Live window's rename list.
    public func speakers() -> [String] { Array(Set(snapshot().lines.map(\.speaker))).sorted() }

    private func saveIfDue() throws {
        if let last = lastSave, now().timeIntervalSince(last) < Self.saveInterval { return }
        try save()
    }

    private func save() throws {
        guard dirty else { return }
        let live = snapshot()
        if lastDiagnostic == nil || now().timeIntervalSince(lastDiagnostic!) >= 30 {
            let kept = echoFiltered()
            for (kind, state) in streams {
                HSLog("live-assignment").info("stream=\(kind.rawValue) " + LiveLineBuilder.diagnostics(words: kept[kind] ?? [], segments: state.segments))
            }
            lastDiagnostic = now()
        }
        onLines?(live.lines)
        if let store, let meetingID { try store.saveLive(live, id: meetingID) }
        lastSave = now(); dirty = false
    }

    // MARK: Echo

    private func applyEcho() {
        let s = streams
        echo.advance(micAudioEnd: s[.mic]?.audioEnd, systemAudioEnd: s[.system]?.audioEnd, matcher: echoMatcher) {
            Self.curve(s[$0], from: $1, to: $2)
        }
    }

    /// Words left after the echo filter's decisions so far.
    func echoFiltered() -> [StreamKind: [Word]] {
        var words = streams.mapValues(\.words)
        if let mic = words[.mic], let sys = words[.system] {
            (words[.mic], words[.system]) = echo.filter(mic: mic, sys: sys)
        }
        return words
    }

    /// The stream's dBFS curve over meeting time [from, to); silence where the stream had no audio.
    static func curve(_ st: StreamState?, from: Double, to: Double) -> [Float] {
        let count = Int(((to - from) * 100).rounded())
        guard let st, let origin = st.origin else { return [Float](repeating: Loudness.floorDBFS, count: count) }
        let first = Int(((from - origin) * 100).rounded())
        return (0..<count).map { i in
            let j = first + i
            return j >= 0 && j < st.loudness.count ? st.loudness[j] : Loudness.floorDBFS
        }
    }

    // MARK: Engines

    private func engine(_ kind: StreamKind) async throws -> Engines {
        if let e = engines[kind] { return e }
        if let t = loading[kind] { return try await t.value }
        let t = Task { () throws -> Engines in
            let start = Date()
            // 1120 ms tier: per FluidAudio's doc, lower latency and better WER than the 2080 ms default.
            let asr = StreamingUnifiedAsrManager(config: UnifiedConfig(leftFrames: 70, chunkFrames: 7, rightFrames: 7))
            try await asr.loadModels()
            let diarizer = LSEENDDiarizer()
            var v = Self.variant(await self.diarizerVariant[kind])
            do {
                try await diarizer.initialize(variant: v, stepSize: .step100ms, computeUnits: .cpuOnly)
            } catch where v != .ami {
                // A model that fails to download must not cost the live transcript: fall back to ami,
                // which earlier releases already downloaded, instead of retrying on every chunk.
                HSLog("live").error("Live diarizer \(v) for \(kind.rawValue) failed (\(error)); using ami")
                v = .ami
                try await diarizer.initialize(variant: v, stepSize: .step100ms, computeUnits: .cpuOnly)
            }
            HSLog("live").info("Live diarizer for \(kind.rawValue): LS-EEND \(v)")
            Self.log.info("Live engines for \(kind.rawValue, privacy: .public) loaded in \(Date().timeIntervalSince(start))s")
            return Engines(asr: asr, diarizer: diarizer)
        }
        loading[kind] = t
        do {
            let e = try await t.value
            engines[kind] = e
            loading[kind] = nil
            return e
        } catch {
            loading[kind] = nil
            throw error
        }
    }

    static func appendTokens(_ timings: [TokenTiming], origin: Double, to words: inout [Word]) {
        LiveLineBuilder.appendTokens(timings.map { ($0.token, origin + $0.startTime, origin + $0.endTime) }, to: &words)
    }

    static func segments(_ d: LSEENDDiarizer, origin: Double) -> [LiveLineBuilder.Segment] {
        d.timeline.speakers.values.flatMap { sp in
            (sp.finalizedSegments + sp.tentativeSegments).map {
                LiveLineBuilder.Segment(slot: $0.speakerIndex, start: origin + Double($0.startTime), end: origin + Double($0.endTime))
            }
        }
    }

    static func pcmBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count) }
        return buf
    }
}
