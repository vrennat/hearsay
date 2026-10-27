import ArgumentParser
import Foundation
import HearsayCore

@main
struct HearsayCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hearsay",
        abstract: "Hearsay meeting tools. Every command takes --root (default ~/Meetings).",
        version: HearsayCore.version,
        subcommands: [Import.self, ProcessCommand.self, CleanupCommand.self, CompressCommand.self, RenameCommand.self, NamesCommand.self, TitleCommand.self, VoicesCommand.self, Speakers.self, Hints.self, SummariesCommand.self, RetentionCommand.self, Dictate.self, LiveSim.self, Reindex.self, LockCommand.self, UnlockCommand.self, ExportCommand.self]
    )

    mutating func run() async throws {
        print(HearsayCLI.helpMessage())
    }
}

struct RootOption: ParsableArguments {
    @Option(name: .long, help: "Meetings folder. Never saved.")
    var root: String?

    /// The store, with the transcript key registered when this root's transcripts are encrypted and
    /// `HEARSAY_PASSWORD` is set (or a TTY answered the prompt). Without it, commands that only need
    /// `meeting.json` still work and transcript reads fail with a clear error.
    var store: MeetingStore {
        let s = plainStore
        if s.transcriptsEncrypted, s.transcriptKey == nil, let pw = Password.get(prompt: "Transcript password: ") {
            do { try TranscriptVault.unlock(root: s.root, password: pw) } catch {
                FileHandle.standardError.write(Data("hearsay: \(error)\n".utf8))
            }
        }
        return s
    }

    /// The store without asking for a password.
    var plainStore: MeetingStore {
        MeetingStore(root: root.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) })
    }
}

struct Import: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Transcribe an audio file into a new meeting.")

    @Argument(help: "Audio file (WAV, AIFF, CAF, M4A...).") var audio: String
    @Option(help: "Meeting title (default: the file name).") var title: String?
    @Option(help: "Your name, for the voiceprint and 1:1 naming rules.") var me: String?
    @OptionGroup var root: RootOption

    mutating func run() async throws {
        let url = URL(fileURLWithPath: (audio as NSString).expandingTildeInPath)
        let store = root.store
        let log = HSLog("cli")
        log.info("import \(url.path) into \(store.root.path)")
        let id = try await ImportPipeline.run(audio: url, store: store, title: title, options: ProcessOptions(userName: me))
        log.info("import done: \(id)")
        print(store.folder(id).appendingPathComponent("transcript.md").path)
    }
}

struct Reindex: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Regenerate every transcript.md, transcript.raw.md and the index.")
    @OptionGroup var root: RootOption

    mutating func run() throws {
        let store = root.store
        try IndexRenderer.reindex(store: store)
        print("Reindexed \(store.listMeetingIDs().count) meetings in \(store.root.path)")
    }
}

struct Speakers: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List a meeting's speakers with labels, names and talk time.")
    @Argument(help: "Meeting id (folder name).") var id: String
    @OptionGroup var root: RootOption

    mutating func run() throws {
        let store = root.store
        let meeting = try store.loadMeeting(id)
        guard let transcript = try store.loadTranscript(id) else {
            throw ValidationError("\(id) has no transcript.json yet")
        }
        for s in SpeakerSummary.summarize(transcript, names: meeting.speakerNames) {
            let talk = String(format: "%d:%02d", Int(s.talkSeconds) / 60, Int(s.talkSeconds) % 60)
            print("\(s.id)\t\(s.label)\t\(s.name ?? "-")\t\(talk)\(s.main ? "" : "\t(minor)")")
        }
    }
}
