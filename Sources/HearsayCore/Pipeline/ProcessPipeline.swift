import Foundation

/// Loaded models, reused across meetings. Each is its own actor and loads lazily on first use.
/// `shared` is the one set per process behind `process`, `import` and `voices`; the live transcriber
/// and dictation keep their own instances so neither waits on a meeting being processed.
public struct PipelineEngines: Sendable {
    public static let shared = PipelineEngines()

    public let transcriber: ParakeetTranscriber
    public let diarizer: SpeakerDiarizer
    public let embedder: VoiceEmbedder

    public init(transcriber: ParakeetTranscriber = ParakeetTranscriber(), diarizer: SpeakerDiarizer = SpeakerDiarizer(),
                embedder: VoiceEmbedder = VoiceEmbedder()) {
        self.transcriber = transcriber; self.diarizer = diarizer; self.embedder = embedder
    }
}

public struct ProcessOptions: Sendable {
    public static let defaultsSuite = "com.tannervass.hearsay"

    /// Write `cleanup.json` (setting `cleanup`, default on).
    public var cleanup: Bool
    /// Your name when `meeting.json` has no `me`; nil skips voiceprint and the 1:1 rules.
    public var userName: String?
    public var compress: Bool
    /// Encrypt the recording after transcription (setting `encryptRecordings`, default on).
    public var encryptAudio: Bool
    public var engines: PipelineEngines
    /// Proposes a title when the meeting's is generic (`TitleGenerator`); tests pass a stub.
    public var titleModel: any TitleModel

    public init(cleanup: Bool = true, userName: String? = nil, compress: Bool = true, encryptAudio: Bool = true,
                engines: PipelineEngines = .shared, titleModel: any TitleModel = OnDeviceTitleModel()) {
        self.cleanup = cleanup; self.userName = userName; self.compress = compress; self.encryptAudio = encryptAudio
        self.engines = engines; self.titleModel = titleModel
    }

    /// The app's settings: `cleanup` from the `com.tannervass.hearsay` defaults suite (default true).
    public static func fromDefaults(userName: String?, engines: PipelineEngines = .shared) -> ProcessOptions {
        let d = UserDefaults(suiteName: defaultsSuite)
        let cleanup = d?.object(forKey: "cleanup") as? Bool ?? true
        let encrypt = d?.object(forKey: "encryptRecordings") as? Bool ?? true
        return ProcessOptions(cleanup: cleanup, userName: userName, encryptAudio: encrypt, engines: engines)
    }
}

public enum ProcessError: Error, CustomStringConvertible {
    case audioRemoved(String)
    case audioMissing(String)
    /// The meeting was marked `failed`; the message is exactly its stored `error`, so a caller that
    /// writes `String(describing:)` into `meeting.json` (the app's queue) keeps the same text.
    case failed(String)
    public var description: String {
        switch self {
        case .audioRemoved(let id): return "\(id): audio was removed by retention; nothing to process"
        case .audioMissing(let id): return "\(id): no audio file on disk; the existing transcript is kept"
        case .failed(let message): return message
        }
    }
}

/// A meeting with nothing to transcribe. Becomes the meeting's `error`.
enum NothingUsable: Error, CustomStringConvertible {
    case noAudio, noSpeech
    var description: String {
        switch self {
        case .noAudio: return "no audio captured"
        case .noSpeech: return "no speech: every track was missing, empty or below the loudness gate"
        }
    }
}

/// The post-call pipeline (spec "Post-call pipeline"), also `hearsay process`. The app calls
/// `process(meetingID:store:options:)` after each recording.
public enum ProcessPipeline {
    private static let log = HearsayCore.logger("pipeline")

    public static func process(meetingID id: String, store: MeetingStore, options: ProcessOptions = ProcessOptions()) async throws {
        // Recordings conversion rewrites meeting.json too; never both at once.
        await MeetingLock.shared.acquire(id)
        defer { MeetingLock.shared.release(id) }
        try await processLocked(meetingID: id, store: store, options: options)
    }

    private static func processLocked(meetingID id: String, store: MeetingStore, options: ProcessOptions) async throws {
        var meeting = try store.loadMeeting(id)
        // Retention removed the audio: refuse before touching status so it stays `done`.
        if meeting.audioRemovedAt != nil { throw ProcessError.audioRemoved(id) }
        // Encrypted transcripts without the password: refuse before touching status, or the
        // transcript write would fail and mark a good recording `failed`.
        if store.transcriptsEncrypted, store.transcriptKey == nil { throw CryptoError.transcriptsLocked }
        // Encrypted audio without the Keychain key: refuse too, so a lost key never turns a meeting `failed`.
        if meeting.streams.contains(where: { EncryptedFile.isEncrypted(URL(fileURLWithPath: $0.file)) }) { _ = try AudioKey.existing() }
        let old = try? store.loadTranscript(id)
        // A transcribed meeting whose audio files are gone (copied without audio/, deleted by hand)
        // keeps its transcript and status: refuse, as for retention.
        let folder = store.folder(id)
        if old != nil, !meeting.streams.contains(where: { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.file).path) }) {
            throw ProcessError.audioMissing(id)
        }
        // Launch recovery marks a crashed recording `interrupted`; that stays in `error` even when
        // processing succeeds, so the folder still says it is partial.
        let interrupted = meeting.error?.hasPrefix(RecordingLifecycle.interruptedError) == true
        meeting.status = .processing
        meeting.error = interrupted ? RecordingLifecycle.interruptedError : nil
        try store.saveMeeting(meeting)

        do {
            let tracks = try Track.load(meeting, store: store)
            guard !tracks.isEmpty else { throw NothingUsable.noAudio }
            var transcript = try await transcribe(meeting.id, tracks: tracks, engines: options.engines)
            guard !transcript.utterances.isEmpty else { throw NothingUsable.noSpeech }
            transcript = Glossary.load(root: store.root).apply(to: transcript)
            try await SpeakerIdentity.embed(&transcript, tracks: tracks, embedder: options.engines.embedder)
            SpeakerIdentity.name(&transcript, meeting: &meeting, store: store, userName: options.userName)
            if meeting.endedAt == nil, let longest = tracks.map({ $0.startOffset + $0.duration }).max() {
                meeting.endedAt = meeting.startedAt.addingTimeInterval(longest)
            }
            if let old { warnIfRoomMoved(id: id, old: old, new: transcript, names: meeting.speakerNames) }

            try store.saveTranscript(transcript, id: id)
            let cleanup = options.cleanup ? TextCleaner.cleanup(for: transcript) : nil
            if let cleanup { try store.saveCleanup(cleanup, id: id) }
            // After transcript.json is safe: the model can take seconds and never throws (it falls back
            // to `Titler`). The reindex below re-renders the Markdown with the new title.
            meeting.title = await TitleGenerator.title(meeting: meeting, transcript: transcript, cleanup: cleanup,
                                                       model: options.titleModel).title
            meeting.status = .done
            try store.saveMeeting(meeting)
        } catch {
            let message = (interrupted ? "\(RecordingLifecycle.interruptedError); " : "") + String(describing: error)
            meeting.status = .failed
            meeting.error = message
            try? store.saveMeeting(meeting)
            try? IndexRenderer.reindex(store: store)
            log.error("\(id, privacy: .public) failed: \(message, privacy: .public)")
            throw ProcessError.failed(message)
        }
        // After transcript.json is safe; a failed stream keeps its original file.
        // Best effort after `done`: a locked Keychain or a failed write must not turn a good meeting `failed`.
        do {
            if options.compress { try await AudioCompressor.compressMeeting(id, store: store, encrypt: options.encryptAudio) }
            // Anything still plain (compression off or failed) is encrypted as is.
            if options.encryptAudio { try AudioVault.encryptMeeting(id, store: store) }
        } catch {
            log.error("\(id, privacy: .public): compress/encrypt audio failed, left as is: \(String(describing: error), privacy: .public)")
        }
        try IndexRenderer.reindex(store: store)
    }

    /// Steps 1 to 3: gate, transcribe, echo filter, diarize and attribute, per track.
    static func transcribe(_ id: String, tracks: [Track], engines: PipelineEngines) async throws -> Transcript {
        var words: [StreamKind: [Word]] = [:]
        var curves: [StreamKind: [Float]] = [:]
        for t in tracks {
            let curve = t.meetingCurve
            curves[t.kind] = curve
            guard Loudness.passesGate(Loudness.curve(t.samples)) else {
                let own = Loudness.curve(t.samples)
                let need = Loudness.requiredLoudSeconds(duration: Double(own.count) * Loudness.frameSeconds)
                let line = Loudness.gateThreshold(own)
                log.info("\(id, privacy: .public): \(t.kind.rawValue, privacy: .public) has \(Loudness.loudSeconds(own, above: line))s above \(line) dBFS of \(need)s needed; not transcribed")
                continue
            }
            let r = try await engines.transcriber.transcribe(t.samples)
            words[t.kind] = r.words.map { tidy(Word(text: $0.text, start: $0.start + t.startOffset, end: $0.end + t.startOffset)) }
        }

        if let mc = curves[.mic], let sc = curves[.system], let mw = words[.mic], let sw = words[.system] {
            let r = EchoFilter.run(micCurve: mc, sysCurve: sc, mic: mw, sys: sw)
            words[.mic] = r.mic
            words[.system] = r.sys
            log.info("\(id, privacy: .public): echo filter kept \(r.confirmedWindows) windows, dropped \(r.droppedMic) mic and \(r.droppedSys) system words")
        }

        var speakers: [Speaker] = []
        var utterances: [Utterance] = []
        for t in tracks {
            guard let w = words[t.kind], !w.isEmpty else { continue }
            var segments: [DiarSegment] = []
            do {
                segments = try await engines.diarizer.diarize(t.samples)
                    .map { DiarSegment(slot: $0.slot, start: $0.start + t.startOffset, end: $0.end + t.startOffset) }
            } catch {
                // One voice is a better transcript than none.
                log.error("\(id, privacy: .public): diarizing \(t.kind.rawValue, privacy: .public) failed, one speaker: \(String(describing: error), privacy: .public)")
            }
            let built = Attribution.build(words: w, segments: segments, stream: t.kind)
            speakers += built.speakers
            utterances += built.utterances
        }
        utterances.sort { $0.start < $1.start }
        return Transcript(
            engine: ParakeetTranscriber.engineName, diarizer: SpeakerDiarizer.name,
            processedAt: JSONCoding.millisecondRounded(Date()), speakers: speakers, utterances: utterances)
    }

    /// Longest a single word may last. Parakeet emits a stray "." in a long silence and FluidAudio's
    /// word merge glues it to the word before, stretching it across the pause (seen 2026-10-23: "first.."
    /// lasting 8.7 s), which hides the pause from `Segmenter` and inflates talk time.
    static let maxWordSeconds = 1.5

    static func tidy(_ w: Word) -> Word {
        var text = w.text
        while let last = text.last, ".?!".contains(last), text.dropLast().last == last { text.removeLast() }
        return Word(text: text, start: w.start, end: min(w.end, w.start + maxWordSeconds))
    }

    /// Spec step 10: reprocessing an older room-on-call meeting moves the room from `sys-*` to
    /// `mic-*` ids, so names typed for the old ids may now land on other voices.
    static func warnIfRoomMoved(id: String, old: Transcript, new: Transcript, names: [String: String]) {
        let oldSys = old.speakers.filter { $0.stream == .system }.count
        let newSys = new.speakers.filter { $0.stream == .system }.count
        let newMic = new.speakers.filter { $0.stream == .mic }.count
        let oldMic = old.speakers.filter { $0.stream == .mic }.count
        guard newSys < oldSys, newMic > oldMic else { return }
        let named = names.keys.filter { $0.hasPrefix("sys-") || $0.hasPrefix("mic-") }.sorted().joined(separator: ", ")
        log.warning("\(id, privacy: .public): reprocessing moved voices from sys-* (\(oldSys) -> \(newSys)) to mic-* (\(oldMic) -> \(newMic)); names typed for old ids may now be on other voices: \(named, privacy: .public)")
    }
}
