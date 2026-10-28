import ArgumentParser
import Foundation
import HearsayCore

struct ProcessCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",abstract: "Run the post-call pipeline on a meeting folder.")
    @Argument(help: "Meeting id (folder name).") var id: String
    @Flag(inversion: .prefixedNo, help: "Write cleanup.json (fillers and repeats removed).") var cleanup = true
    @Flag(inversion: .prefixedNo, help: "Re-encode tracks to AAC .m4a afterwards.") var compress = true
    @Flag(inversion: .prefixedNo, help: "Encrypt the audio afterwards (key in the login Keychain).") var encrypt = true
    @Option(help: "Your name, when meeting.json has no `me`; enables the voiceprint and 1:1 rules.") var me: String?
    @OptionGroup var root: RootOption

    mutating func run() async throws {
        let store = root.store
        try await ProcessPipeline.process(meetingID: id, store: store,
                                          options: ProcessOptions(cleanup: cleanup, userName: me, compress: compress, encryptAudio: encrypt))
        print(store.folder(id).appendingPathComponent("transcript.md").path)
    }
}

struct CleanupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cleanup",abstract: "Write cleanup.json (fillers and repeated words removed) and re-render.")
    @Argument(help: "Meeting id (folder name).") var id: String
    @OptionGroup var root: RootOption

    mutating func run() throws {
        let store = root.store
        guard let t = try store.loadTranscript(id) else { throw ValidationError("\(id) has no transcript.json yet") }
        try store.saveCleanup(TextCleaner.cleanup(for: t), id: id)
        try IndexRenderer.reindex(store: store)
        print(store.folder(id).appendingPathComponent("transcript.md").path)
    }
}

struct CompressCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compress",abstract: "Re-encode a meeting's non-.m4a tracks to AAC .m4a and delete the originals.")
    @Argument(help: "Meeting id (folder name).") var id: String
    @Flag(inversion: .prefixedNo, help: "Write the result as .m4a.enc (an encrypted source always stays encrypted).") var encrypt = true
    @OptionGroup var root: RootOption

    mutating func run() async throws {
        let n = try await AudioCompressor.compressMeeting(id, store: root.plainStore, encrypt: encrypt)
        print("Compressed \(n) stream(s)")
    }
}

struct RenameCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",abstract: "Name a speaker (empty name clears it) and re-render.")
    @Argument(help: "Meeting id (folder name).") var id: String
    @Argument(help: "Speaker id, e.g. mic-1 or sys-2.") var speaker: String
    @Argument(help: "Name.") var name: String
    @OptionGroup var root: RootOption

    mutating func run() throws {
        let n = try MeetingEdits.rename(id: id, speaker: speaker, name: name, store: root.store)
        print("\(speaker)\t\(n.isEmpty ? "-" : n)")
    }
}

struct DiarizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diarize",
        abstract: "Re-run the diarizer on a meeting's audio at several clustering thresholds and print the voices found. Writes nothing.",
        discussion: "Lower thresholds split more voices (default 0.6). Use it to tune diarization on a real recording.")
    @Argument(help: "Meeting id (folder name).") var id: String
    @Option(help: "Stream: mic or system.") var stream: String = "system"
    @Option(parsing: .upToNextOption, help: "Thresholds to try.") var thresholds: [Double] = [0.6, 0.5, 0.45, 0.4, 0.35, 0.3]
    @Option(help: "Also require at least this many voices.") var minSpeakers: Int?
    @Option(help: "VBx Fa (default 0.07; higher trusts the acoustics more).") var fa: Double?
    @Option(help: "VBx Fb (default 0.8; lower allows more speakers).") var fb: Double?
    @Option(help: "VBx iterations (default 20; 1 stays closest to the first clustering).") var vbxIterations: Int?
    @Option(help: "Shortest speech an embedding is taken from, seconds (default 1.0).") var minEmbeddingSeconds: Double?
    @Flag(help: "Take embeddings from overlapped speech too.") var includeOverlap = false
    @OptionGroup var root: RootOption

    mutating func run() async throws {
        let store = root.store
        let m = try store.loadMeeting(id)
        guard let kind = StreamKind(rawValue: stream), let track = try Track.load(m, store: store).first(where: { $0.kind == kind }) else {
            throw ValidationError("No \(stream) audio in \(id)")
        }
        print("\(stream): \(Int(Double(track.samples.count) / AudioLoader.sampleRate)) s")
        for t in thresholds {
            var tuning = SpeakerDiarizer.Tuning()
            tuning.threshold = t; tuning.minSpeakers = minSpeakers; tuning.fa = fa; tuning.fb = fb
            tuning.vbxIterations = vbxIterations; tuning.minEmbeddingSeconds = minEmbeddingSeconds
            tuning.includeOverlap = includeOverlap
            let segs = try await SpeakerDiarizer(tuning: tuning).diarize(track.samples)
            var talk: [String: Double] = [:]
            for s in segs { talk[s.slot, default: 0] += s.end - s.start }
            let voices = talk.sorted { $0.value > $1.value }.map { "\(Int($0.value))s" }.joined(separator: " ")
            print("threshold \(t)\t\(talk.count) voices\t\(segs.count) segments\t\(voices)")
        }
    }
}

struct NamesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "names",
        abstract: "List guessed and unconfirmed names by person; --confirm NAME confirms that person everywhere.",
        discussion: "Only confirmed names help recognise voices in other meetings.")
    @Option(help: "Confirm every unconfirmed use of this name.") var confirm: String?
    @Option(help: "Your name, left out of the list (default: none).") var me: String?
    @OptionGroup var root: RootOption

    mutating func run() throws {
        let store = root.store
        let people = NameReview.pending(store: store, me: me)
        if let confirm {
            guard let p = people.first(where: { $0.name.caseInsensitiveCompare(confirm) == .orderedSame }) else {
                throw ValidationError("No unconfirmed name \(confirm)")
            }
            print("Confirmed \(try NameReview.confirm(p.entries, name: p.name, store: store)) uses of \(p.name)")
            return
        }
        if people.isEmpty { print("No names to confirm."); return }
        for p in people { print("\(p.name)\t\(p.entries.count) meeting\(p.entries.count == 1 ? "" : "s")") }
    }
}

struct TitleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "title",
        abstract: "Set a meeting's title, or ask the on-device model for one. The folder name is unchanged.",
        discussion: """
            hearsay title <id> <title>   set it by hand (never retitled afterwards)
            hearsay title <id> --suggest print the model's proposal, write nothing
            hearsay title <id> --apply   write the model's proposal
            """)
    @Argument(help: "Meeting id (folder name).") var id: String
    @Argument(help: "Title. Omit with --suggest or --apply.") var title: String?
    @Flag(help: "Print the on-device model's proposed title without writing it.") var suggest = false
    @Flag(help: "Write the on-device model's proposed title.") var apply = false
    @OptionGroup var root: RootOption

    func validate() throws {
        if suggest && apply { throw ValidationError("Use --suggest or --apply, not both.") }
        if (suggest || apply) == (title != nil) { throw ValidationError("Give a title, or --suggest / --apply.") }
    }

    mutating func run() async throws {
        let store = root.store
        if let title {
            print(try MeetingEdits.setTitle(id: id, title: title, store: store))
            return
        }
        let meeting = try store.loadMeeting(id)
        guard let transcript = try store.loadTranscript(id) else { throw ValidationError("\(id) has no transcript.json yet") }
        let cleanup = (try? store.loadCleanup(id)) ?? nil
        let start = Date()
        let outcome = await TitleGenerator.suggest(meeting: meeting, transcript: transcript, cleanup: cleanup)
        let seconds = String(format: "%.2f", Date().timeIntervalSince(start))
        HSLog("cli").info("title \(id) --\(apply ? "apply" : "suggest"): \(outcome.source.rawValue) in \(seconds) s")
        guard outcome.source == .generated else {
            print("No title proposed: \(outcome.reason ?? "unknown"). Current title: \(meeting.title)")
            throw ExitCode.failure
        }
        if apply { print(try MeetingEdits.applyGeneratedTitle(id: id, title: outcome.title, store: store)) }
        else { print(outcome.title) }
        FileHandle.standardError.write(Data("\(seconds) s, availability \(OnDeviceTitleModel.availabilityDescription)\n".utf8))
    }
}

struct VoicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "voices",
        abstract: "Backfill voice embeddings and inferred names without re-transcribing. Lists the plan; --apply writes it.")
    @Argument(help: "Meeting ids (default: every meeting).") var ids: [String] = []
    @Flag(help: "Write transcript.json voices and meeting.json names.") var apply = false
    @Option(help: "Your name, when meeting.json has no `me`.") var me: String?
    @OptionGroup var root: RootOption

    mutating func run() async throws {
        for r in try await VoiceBackfill.run(store: root.store, ids: ids, userName: me, apply: apply) {
            let changed = r.previousName == r.name ? "" : "\t(was \(r.previousName ?? "-"))"
            print("\(r.meetingID)\t\(r.speaker)\t\(r.label)\t\(r.name ?? "-")\(changed)\t\(r.voice)")
        }
    }
}
