import AppKit
import Foundation
import HearsayCore
import Observation

/// Everything the meeting window shows for one meeting, reloaded from disk after every edit and after
/// the processing queue finishes it.
@MainActor @Observable
final class MeetingModel {
    struct SpeakerRow: Identifiable {
        let id: String
        let label: String
        let name: String?
        let talkSeconds: Double
        let stream: StreamKind
    }

    private let log = HSLog("meeting-window")
    let id: String
    private(set) var store: MeetingStore
    private(set) var meeting: Meeting
    private(set) var transcript: Transcript?
    private(set) var lines = TranscriptLines(source: .none, lines: [])
    private(set) var liveNames: [String: String] = [:]
    private(set) var speakers: [SpeakerRow] = []
    private(set) var hints: [String: NameHints.Hint] = [:]
    private(set) var summaries: [String: String] = [:]
    private(set) var summaryNote: String?
    private(set) var files: [URL] = []
    private(set) var player: MeetingPlayer?
    private(set) var editError: String?
    var followPlayback = true
    @ObservationIgnored private var summaryTask: Task<Void, Never>?
    @ObservationIgnored private var summarizedAt: Date?

    init(meeting: Meeting, store: MeetingStore) {
        self.id = meeting.id
        self.store = store
        self.meeting = meeting
        reload()
    }

    var isRecording: Bool { MainWindowModel.shared.recordingID == id }  // the preview's stand-in too
    var isQueued: Bool { AppModel.shared.queue.busy.contains(id) }
    /// Being transcribed now (the queue's current item), as opposed to waiting in the queue.
    var isProcessing: Bool { AppModel.shared.queue.current == id }
    /// The status word and symbol, from the same inputs the sidebar row uses.
    var statusWord: String { MeetingStatusSymbol.word(meeting, processing: isProcessing, queued: AppModel.shared.queue.pending.contains(id)) }
    var statusSymbol: String { MeetingStatusSymbol.name(meeting, processing: isProcessing, queued: AppModel.shared.queue.pending.contains(id)) }
    var canReprocess: Bool {
        !isRecording && !isQueued && meeting.audioRemovedAt == nil && !meeting.streams.isEmpty
    }

    /// Banner text for a failed or interrupted meeting.
    var banner: String? {
        if meeting.status == .failed {
            return "Processing failed: \(meeting.error ?? "unknown error")"
        }
        if let e = meeting.error, e.hasPrefix("interrupted") {
            return "This recording was interrupted (Hearsay quit or crashed). What was captured has been processed."
        }
        return nil
    }

    func reload() {
        if let m = try? store.loadMeeting(id) { meeting = m }
        transcript = (try? store.loadTranscript(id)) ?? nil
        lines = TranscriptLines.load(store: store, id: id)
        liveNames = ((try? store.loadLive(id)) ?? nil)?.speakerNames ?? [:]
        speakers = makeSpeakers()
        files = Self.listFiles(store.folder(id))
        if let transcript {
            hints = Dictionary(NameHints.hints(utterances: transcript.utterances,
                                               candidates: NameHints.candidates(for: meeting, store: store))
                .map { ($0.speaker, $0) }, uniquingKeysWith: { a, _ in a })
            summarize(transcript)
        } else {
            hints = [:]
        }
        updatePlayer()
    }

    private func makeSpeakers() -> [SpeakerRow] {
        if let transcript {
            return SpeakerSummary.summarize(transcript, names: meeting.speakerNames)
                .map { s in
                    SpeakerRow(id: s.id, label: s.label, name: s.name, talkSeconds: s.talkSeconds,
                               stream: transcript.speaker(s.id)?.stream ?? .mic)
                }
                .sorted { $0.talkSeconds > $1.talkSeconds }
        }
        // Live only: one row per live voice, read-only (live ids differ from the final speakers').
        var talk: [String: Double] = [:]
        for l in lines.lines { talk[l.speaker, default: 0] += max(0, l.end - l.start) }
        return talk.keys.sorted().map { k in
            SpeakerRow(id: k, label: lines.source == .liveMarkdown ? k : LiveModel.defaultLabel(k),
                       name: liveNames[k], talkSeconds: talk[k] ?? 0, stream: k.hasPrefix("sys") ? .system : .mic)
        }
    }

    /// The name shown on a transcript line.
    func displayName(_ speaker: String) -> String {
        switch lines.source {
        case .transcript, .cleanedTranscript:
            return meeting.speakerNames[speaker] ?? transcript?.speaker(speaker)?.defaultLabel ?? speaker
        case .live: return liveNames[speaker] ?? LiveModel.defaultLabel(speaker)
        case .liveMarkdown, .none: return speaker
        }
    }

    var canRename: Bool { transcript != nil }

    // MARK: Edits (same code paths as `hearsay title` / `hearsay rename`)

    func setTitle(_ title: String) {
        do {
            try MeetingEdits.setTitle(id: id, title: title, store: store)
            editError = nil
            log.info("Title of \(id) set (\(title.count) chars)")
        } catch {
            editError = "Could not save the title: \(error)"
            log.error("Title of \(id): \(error)")
        }
        reload()
        AppModel.shared.refreshRecent()
    }

    /// A name naming guessed (or one from before guesses were recorded) that you have not confirmed.
    func isGuess(_ speaker: String) -> Bool { meeting.nameIsGuess(speaker) }

    /// Confirms a guessed name, so it helps recognise this voice in other meetings.
    func confirm(_ speaker: String) {
        guard let name = meeting.speakerNames[speaker] else { return }
        do {
            try NameReview.confirm([.init(meetingID: id, speaker: speaker)], name: name, store: store)
            editError = nil
            log.info("Confirmed \(speaker) in \(id)")
        } catch {
            editError = "Could not confirm the name: \(error)"
            log.error("Confirm \(speaker) in \(id): \(error)")
        }
        reload()
    }

    /// Lines from the final transcript (not the live fallback) can be moved to another speaker.
    var canReassign: Bool { (lines.source == .transcript || lines.source == .cleanedTranscript) && !isQueued && !isRecording }

    /// Speakers a line could move to: the other voices on its side (room or call).
    func moveTargets(for line: TranscriptLines.Line) -> [SpeakerRow] {
        guard let stream = speakers.first(where: { $0.id == line.speaker })?.stream else { return [] }
        return speakers.filter { $0.stream == stream && $0.id != line.speaker }
    }

    /// Moves one line to `target`, or to a new speaker when nil.
    func move(_ line: TranscriptLines.Line, to target: String?) {
        do {
            let dest = try MeetingEdits.reassign(id: id, utterances: [line.id], to: target, store: store)
            editError = nil
            log.info("Moved line \(line.id) in \(id) to \(dest)")
        } catch {
            editError = "Could not move the line: \(error)"
            log.error("Move line \(line.id) in \(id): \(error)")
        }
        reload()
    }

    func rename(_ speaker: String, to name: String) {
        do {
            try MeetingEdits.rename(id: id, speaker: speaker, name: name, store: store)
            editError = nil
            log.info("Renamed \(speaker) in \(id)")
        } catch {
            editError = "Could not save the name: \(error)"
            log.error("Rename \(speaker) in \(id): \(error)")
        }
        reload()
    }

    var hasCallAudio: Bool { meeting.streams.contains { $0.kind == .system } }

    /// Saves how many people spoke on the call and re-transcribes with at least that many call voices.
    func rediarize(callSpeakers n: Int) {
        guard canReprocess else { return }
        do {
            try MeetingEdits.setCallSpeakers(id: id, count: n, store: store)
            editError = nil
            log.info("\(id): call speakers set to \(n)")
        } catch {
            editError = "Could not save the speaker count: \(error)"
            return
        }
        reload()
        reprocess()
    }

    func reprocess() {
        guard canReprocess else { return }
        player?.pause()
        AppModel.shared.queue.enqueue(id)
    }

    // MARK: Summaries (hint only, never saved)

    private func summarize(_ t: Transcript) {
        guard summarizedAt != t.processedAt else { return }
        summarizedAt = t.processedAt
        summaryTask?.cancel()
        summaries = [:]
        if let reason = SpeakerSummaries.unavailableReason() {
            summaryNote = "No speaker summaries: \(reason)"
            return
        }
        summaryNote = nil
        summaryTask = Task { [weak self] in
            do {
                let lines = try await SpeakerSummaries.summarize(t)
                guard !Task.isCancelled else { return }
                self?.summaries = Dictionary(lines.map { ($0.speaker, $0.text) }, uniquingKeysWith: { a, _ in a })
            } catch {
                self?.summaryNote = "No speaker summaries: \(error)"
            }
        }
    }

    // MARK: Playback

    private func updatePlayer() {
        if isRecording {
            player?.tearDown()
            player = nil
            return
        }
        guard player == nil, !meeting.streams.isEmpty, meeting.audioRemovedAt == nil else { return }
        let meeting = meeting, folder = store.folder(id)
        Task { [weak self] in
            let p = await MeetingPlayer.load(meeting: meeting, folder: folder)
            guard let self, self.player == nil, !self.isRecording else { p?.tearDown(); return }
            self.player = p
        }
    }

    /// The line to highlight while following playback.
    var currentLine: Int? {
        guard followPlayback, let p = player, p.isPlaying || p.time > 0 else { return nil }
        return lines.index(at: p.time)
    }

    func recordingStarted(_ meetingID: String) {
        player?.pause()
        if meetingID == id { player?.tearDown(); player = nil }
    }

    func close() {
        summaryTask?.cancel()
        player?.tearDown()
        player = nil
    }

    // MARK: Files

    static func listFiles(_ folder: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        let top = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        for url in top.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDir {
                let inner = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                out += inner.sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else {
                out.append(url)
            }
        }
        return out
    }
}
