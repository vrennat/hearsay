import AppKit
import Foundation
import HearsayCore
import Observation

/// App-wide state. The notch pill, main window, live window, calendar and dictation hang off this.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel(options: LaunchOptions.parse(Array(CommandLine.arguments.dropFirst())))

    private let log = HSLog("app")
    let options: LaunchOptions
    /// `--root` for this run only (never written to defaults), else the saved Meetings folder, else ~/Meetings.
    private(set) var store: MeetingStore
    let queue: ProcessingQueue
    private var retention: RetentionScheduler?
    private let sleepGuard = SleepGuard()
    private(set) var session: RecordingSession? { didSet { publishBusy() } }
    /// The panel and standard menu show this many recent meetings; the main window has the rest.
    static let recentLimit = 5
    private(set) var recent: [Meeting] = []
    private(set) var lastError: String?
    private var starting = false
    private var launched = false

    var isRecording: Bool { session != nil }

    /// Menu bar glyph: recording wins, then a held dictation key, then a meeting being transcribed.
    var menuBarState: MenuBarState {
        if isRecording { return .recording }
        if DictationController.shared.isActive { return .dictating }
        if !queue.isIdle { return .processing }
        return .idle
    }

    init(options: LaunchOptions) {
        self.options = options
        let store = MeetingStore(root: options.root ?? MeetingsFolder.resolveSaved())
        self.store = store
        self.queue = ProcessingQueue(store: store)
        queue.onChange = { BusyMeetings.shared.set(AppModel.shared.busyMeetingIDs) }
        queue.onFinished = { [weak self] id in
            // Retention first: with "Until transcribed" the audio goes now, and the reload sees it gone.
            self?.runRetentionNow {
                self?.refreshRecent()
                MainWindowModel.shared.reload(id)
            }
        }
    }

    func didFinishLaunching() {
        guard !launched else { return }
        launched = true
        log.info("Hearsay \(HearsayCore.version) launched, pid \(getpid()), root \(store.root.path), args \(CommandLine.arguments.dropFirst().joined(separator: " "))")
        RecordingUI.shared.install()
        MeetingOpener.handler = { MainWindowController.shared.show($0) }
        AppWindows.install()
        MeetingPreview.startIfRequested()
        if options.isTestInstance {
            log.info("Test instance: skipping notification permission, crash-report notifications and dictation")
        } else {
            Notifier.requestAuthorization()
            LaunchChecks.postCrashReports()
            DictationController.shared.settingsChanged()
        }
        sleepGuard.recoverAfterCrash()
        MeetingPlayer.sweepPlaybackCopies()
        do { try store.prepare() } catch { log.error("Cannot prepare \(store.root.path): \(error)") }
        // Launch repairs (conversion sweep, interrupted-recording recovery, retention) assume this is
        // the only Hearsay on this store. A headless preview launched while the installed app was
        // recording marked its live meeting "interrupted" and processed it as failed (2026-10-23),
        // so another live holder of the recording lock, or any preview, skips them.
        let lock = RecordingLock()
        let otherRecording = lock.isHeld && lock.holder() != getpid()
        let preview = CommandLine.arguments.contains { $0.hasPrefix("--preview-") }
        if otherRecording || preview {
            log.info("Skipping launch repairs: \(otherRecording ? "another Hearsay (pid \(lock.holder() ?? 0)) is recording" : "preview launch")")
        } else {
            // Before anything is queued: finish or clean up audio conversions a crash cut short.
            AudioVault.sweep(store: store, encrypt: Prefs.encryptRecordingsOn)
            for id in RecordingLifecycle.recoverInterrupted(store: store) { queue.enqueue(id) }
        }
        refreshRecent()
        if !preview { startRetention() }
        if store.transcriptsEncrypted, store.transcriptKey == nil { UnlockWindowController.shared.show() }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop(reason: "system going to sleep") }
        }

        if let seconds = options.recordFor { runTimedRecording(seconds) }
    }

    func start() { Task { await startRecording() } }

    /// Waits for the microphone prompt if one is showing, then starts. Returns whether it is recording.
    @discardableResult
    func startRecording() async -> Bool {
        guard session == nil, !starting else { return session != nil }
        starting = true
        defer { starting = false }
        do {
            let event = await RecordingUI.shared.willStart()
            let s = try await RecordingSession.start(store: store, title: RecordingUI.title(for: event), sleepGuard: sleepGuard)
            session = s
            MainWindowModel.shared.recordingStarted(s.meetingID)
            RecordingUI.shared.didStart(s, event: event)
            lastError = nil
            WindowInventory.log("recording start")
            refreshRecent()
            return true
        } catch {
            lastError = String(describing: error)
            log.error("Could not start recording: \(error)")
            return false
        }
    }

    func stop(reason: String = "user") {
        guard let s = session else { return }
        let m = s.stop(reason: reason)
        session = nil
        refreshRecent()
        // Queued after the live transcript's last save, so the pipeline reads its final names and lines.
        RecordingUI.shared.didStop(s) { [queue] in queue.enqueue(m.id) }
    }

    /// With "Until transcribed" the audio must go as soon as processing ends, not at the next 24 h tick.
    func runRetentionNow(then done: @escaping @MainActor () -> Void) {
        guard let r = retention else { done(); return }
        DispatchQueue.global(qos: .utility).async {
            r.runOnce()
            DispatchQueue.main.async { done() }
        }
    }

    /// Retention at launch and every 24 h; settings and busy ids are read at fire time.
    private func startRetention() {
        retention?.stop()
        log.info("Retention: audio \(Self.days(Prefs.keepAudioDaysValue)), transcripts \(Self.days(Prefs.keepTranscriptDaysValue))")
        let r = RetentionScheduler(store: store) {
            let busy = BusyMeetings.shared.snapshot()  // the timer fires off the main actor
            return .init(keepAudioDays: Prefs.keepAudioDaysValue,
                         keepTranscriptDays: Prefs.keepTranscriptDaysValue, queued: busy)
        }
        retention = r
        r.start()
    }

    private static func days(_ n: Int) -> String { n == 0 ? "forever" : "\(n) d" }

    /// Recording, processing or queued: retention leaves these alone.
    var busyMeetingIDs: Set<String> { queue.busy.union(session.map { [$0.meetingID] } ?? []) }
    private func publishBusy() { BusyMeetings.shared.set(busyMeetingIDs) }

    // MARK: Meetings folder

    var meetingsFolderBlocked: String? {
        if isRecording { return "Stop the recording to change the folder." }
        if !queue.isIdle { return "Wait for processing to finish to change the folder." }
        return nil
    }
    var canChangeMeetingsFolder: Bool { options.root == nil && meetingsFolderBlocked == nil }

    func chooseMeetingsFolder() {
        guard canChangeMeetingsFolder, let url = MeetingsFolder.choose(current: store.root) else { return }
        do {
            try MeetingsFolder.save(url)
        } catch {
            log.error("Cannot save Meetings folder \(url.path): \(error)")
            lastError = "Cannot use \(url.path): \(error.localizedDescription)"
            return
        }
        store = MeetingStore(root: url)
        queue.store = store
        do { try store.prepare() } catch { log.error("Cannot prepare \(store.root.path): \(error)") }
        log.info("Meetings folder is now \(store.root.path)")
        MainWindowModel.shared.storeChanged()
        refreshRecent()
        startRetention()
    }

    // MARK: Encryption

    /// Transcripts are encrypted and the password has not been entered this run.
    var transcriptsLocked: Bool { store.transcriptsEncrypted && store.transcriptKey == nil }

    /// After the password is entered: re-queue meetings that waited for it.
    func transcriptsUnlocked() {
        for m in store.loadAllMeetings() where m.status == .recorded { queue.enqueue(m.id) }
        refreshRecent()
    }

    /// Settings "Encrypt recordings": encrypts or decrypts every idle meeting's audio, off the main actor.
    /// Busy is re-read per meeting (`BusyMeetings` is updated on every enqueue), and `MeetingLock`
    /// keeps the pipeline and the conversion off the same meeting.
    func setRecordingsEncrypted(_ on: Bool) {
        let store = store, log = log
        Task.detached(priority: .utility) {
            let n = AudioVault.convertAll(store: store, encrypt: on) { BusyMeetings.shared.snapshot().contains($0) }
            log.info("\(on ? "Encrypted" : "Decrypted") \(n) recording(s)")
        }
    }

    func refreshRecent() {
        recent = Array(store.loadAllMeetings().sorted { $0.startedAt > $1.startedAt }.prefix(Self.recentLimit))
        if MainWindowController.shared.window?.isVisible == true { MainWindowModel.shared.refresh() }
    }

    func reveal(_ meeting: Meeting) {
        NSWorkspace.shared.activateFileViewerSelecting([store.folder(meeting.id)])
    }

    func menuOpened() {
        WindowInventory.log("menu open")
        CalendarService.shared.refreshForMenu()
        refreshRecent()
    }

    private func runTimedRecording(_ seconds: TimeInterval) {
        log.info("--record-for \(seconds): recording, then quitting")
        // A first run shows the microphone prompt and waits for a human; give up after 60 s.
        Task {
            try? await Task.sleep(for: .seconds(60))
            if session == nil, starting {
                log.error("--record-for: still waiting for microphone permission after 60 s; quitting")
                NSApp.terminate(nil)
            }
        }
        Task {
            guard await startRecording() else {
                log.error("--record-for: recording did not start; quitting")
                NSApp.terminate(nil)
                return
            }
            try? await Task.sleep(for: .seconds(seconds))
            stop(reason: "--record-for \(seconds) elapsed")
            await RecordingUI.shared.waitUntilFlushed()
            await queue.waitUntilIdle()
            log.info("--record-for done; quitting")
            NSApp.terminate(nil)
        }
    }

    func willTerminate() {
        stop(reason: "app quitting")
        MeetingsFolder.end()
    }
}

/// The busy ids (recording, processing, queued) for `RetentionScheduler`, whose timer runs on its own
/// queue: a lock-protected copy the main actor updates, so retention never blocks on the main thread.
final class BusyMeetings: @unchecked Sendable {
    static let shared = BusyMeetings()
    private let lock = NSLock()
    private var ids: Set<String> = []
    func set(_ new: Set<String>) { lock.lock(); ids = new; lock.unlock() }
    func snapshot() -> Set<String> { lock.lock(); defer { lock.unlock() }; return ids }
}
