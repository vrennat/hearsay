import ArgumentParser
import Foundation
import HearsayCore

/// `hearsay hints`, `retention`, `dictate`, `live-sim`.

struct Hints: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Suggest speaker names from how people address each other.")
    @Argument(help: "Meeting id (folder name).") var id: String
    @OptionGroup var root: RootOption

    mutating func run() throws {
        let store = root.store
        let meeting = try store.loadMeeting(id)
        guard let transcript = try store.loadTranscript(id) else { throw ValidationError("\(id) has no transcript.json yet") }
        let hints = NameHints.hints(utterances: transcript.utterances, candidates: NameHints.candidates(for: meeting, store: store))
        if hints.isEmpty { print("No name hints."); return }
        for h in hints {
            let current = meeting.speakerNames[h.speaker].map { " (named \($0))" } ?? ""
            print("\(h.speaker)\(current)\tSounds like \(h.name)\t\"\(h.quote)\" at \(Self.clock(h.at))\(h.votes > 1 ? "\t\(h.votes) cues" : "")")
        }
    }

    static func clock(_ t: Double) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
}

struct RetentionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "retention", abstract: "List (or with --apply, carry out) the retention plan.")
    @Option(name: .customLong("audio-days"), help: "Keep audio this many days (0 = forever, -1 = delete once transcribed).") var audioDays: Int
    @Option(name: .customLong("transcript-days"), help: "Keep meetings this many days (0 = forever).") var transcriptDays: Int
    @Flag(help: "Trash folders and delete audio as planned.") var apply = false
    @OptionGroup var root: RootOption

    mutating func run() throws {
        let store = root.store
        let plan = RetentionPlan.make(store: store, keepAudioDays: audioDays, keepTranscriptDays: transcriptDays)
        for item in plan.items {
            let what = item.action == .trash ? "trash folder" : "delete audio"
            print("\(what)\t\(item.id)\t\(Int(item.ageDays)) days")
        }
        for s in plan.skipped { print("skip (\(s.reason.rawValue))\t\(s.id)") }
        if plan.items.isEmpty { print("Nothing to do.") }
        guard apply, !plan.items.isEmpty else { return }
        let done = Retention.apply(plan, store: store)
        print("Applied \(done.count) of \(plan.items.count).")
        if !done.isEmpty { try IndexRenderer.reindex(store: store) }
    }
}

struct Dictate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the dictation path on a WAV: streaming partials, then the final text.")
    @Argument(help: "Audio file.") var audio: String
    @Option(help: "Playback speed for the streaming pass (1 = real time).") var speed: Double = 1
    @Flag(help: "Remove fillers (the cleanup setting).") var cleanup = false
    @OptionGroup var root: RootOption

    mutating func run() async throws {
        let samples = try AudioLoader.loadMono16k(URL(fileURLWithPath: (audio as NSString).expandingTildeInPath))
        let d = DictationTranscriber(glossary: Glossary.load(root: root.store.root), cleanup: cleanup)
        let loadStart = Date()
        try await d.prepare()
        print(String(format: "models ready in %.2fs; clip %.2fs", Date().timeIntervalSince(loadStart), Double(samples.count) / 16_000))

        let start = Date()
        let last = LockedText()
        try await d.startStreaming { text in
            guard last.swap(text) != text else { return }
            print(String(format: "[%5.2fs] %@", Date().timeIntervalSince(start), text))
        }
        try await feed(samples, speed: speed, start: start) { try await d.appendStreaming($0) }
        _ = await d.endStreaming()
        let streamDone = Date().timeIntervalSince(start)

        let result = try await d.transcribe(samples)
        print(String(format: "streaming done at %.2fs", streamDone))
        print(String(format: "final in %.3fs: %@", result.seconds, result.text))
    }
}

struct LiveSim: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "live-sim", abstract: "Feed WAVs through the live transcriber into a scratch meeting folder.")
    @Argument(help: "Mic stream audio file.") var audio: String
    @Option(help: "System stream audio file.") var second: String?
    @Option(help: "Playback speed (1 = real time, 0 = as fast as possible).") var speed: Double = 1
    @Option(help: "LS-EEND model for the system stream: ami, callhome, dihard2, dihard3.") var variant: String?
    @OptionGroup var root: RootOption

    mutating func run() async throws {
        let store = root.store
        try store.prepare()
        let mic = try AudioLoader.loadMono16k(URL(fileURLWithPath: (audio as NSString).expandingTildeInPath))
        let sys = try second.map { try AudioLoader.loadMono16k(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) }
        let started = Date()
        let id = store.newMeetingID(startedAt: started, title: "live-sim")
        try FileManager.default.createDirectory(at: store.folder(id), withIntermediateDirectories: true)
        try store.saveMeeting(Meeting(id: id, title: "live-sim", startedAt: started, status: .recorded))

        let live = LiveTranscriber()
        if let variant { await live.setDiarizerVariant(variant, for: .system) }
        let loadStart = Date()
        try await live.preload()
        print(String(format: "engines ready in %.2fs", Date().timeIntervalSince(loadStart)))
        let printed = LockedCount()
        let t0 = Date()
        await live.begin(meetingID: id, store: store) { lines in
            let n = printed.advance(to: lines.count)
            // Print lines that are complete (not the last, which may still grow).
            for l in lines.prefix(max(0, lines.count - 1)).dropFirst(n) {
                print(String(format: "[wall %5.1fs] %@ %5.1f-%5.1f %@", Date().timeIntervalSince(t0), l.speaker, l.start, l.end, l.text))
            }
        }
        let chunk = 1_600  // 100 ms
        var i = 0
        let total = max(mic.count, sys?.count ?? 0)
        while i < total {
            let offset = Double(i) / 16_000
            if i < mic.count { try await live.append(Array(mic[i..<min(i + chunk, mic.count)]), at: offset, stream: .mic) }
            if let sys, i < sys.count { try await live.append(Array(sys[i..<min(i + chunk, sys.count)]), at: offset, stream: .system) }
            i += chunk
            if speed > 0 {
                let due = Double(i) / 16_000 / speed - Date().timeIntervalSince(t0)
                if due > 0 { try await Task.sleep(nanoseconds: UInt64(due * 1e9)) }
            }
        }
        let final = try await live.finish()
        print(String(format: "finished at wall %.1fs for %.1fs of audio; %d lines", Date().timeIntervalSince(t0), Double(total) / 16_000, final.lines.count))
        for l in final.lines { print(String(format: "%@ %5.1f-%5.1f %@", l.speaker, l.start, l.end, l.text)) }
        print(store.folder(id).appendingPathComponent(MeetingStore.liveMarkdownFile).path)
    }
}

/// Feeds samples in 100 ms chunks paced at `speed` (0 = no pacing).
func feed(_ samples: [Float], speed: Double, start: Date, _ body: ([Float]) async throws -> Void) async throws {
    let chunk = 1_600
    var i = 0
    while i < samples.count {
        try await body(Array(samples[i..<min(i + chunk, samples.count)]))
        i += chunk
        if speed > 0 {
            let due = Double(i) / 16_000 / speed - Date().timeIntervalSince(start)
            if due > 0 { try await Task.sleep(nanoseconds: UInt64(due * 1e9)) }
        }
    }
}

final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func swap(_ new: String) -> String { lock.withLock { let old = value; value = new; return old } }
}

final class LockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var printed = 0
    /// Returns how many complete lines were printed before, and records `count - 1` as printed now.
    func advance(to count: Int) -> Int { lock.withLock { let old = printed; printed = max(printed, count - 1); return old } }
}
