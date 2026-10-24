import AppKit
import Foundation
import HearsayCore
import UserNotifications

/// Recording-time UI and wiring around `RecordingSession`: calendar at Start, the notch pill, the live
/// model, end detection and the "Meeting over?" prompt. `AppModel` and `RecordingSession` call the
/// hooks below; everything else lives here so the session stays about capture.
@MainActor
final class RecordingUI {
    static let shared = RecordingUI()
    private let log = HSLog("recording-ui")
    private let endWatch = EndWatch()
    private var askedNotifications = false
    private var pill: PillModel?
    private var lastPillSecond = -1
    private var finishing: Task<Void, Never>?
    private var micSilentAnnounced = false

    /// Launch: notification delegate and categories; `--preview-pill`.
    func install() {
        NotificationRouter.shared.install()
        EndWatch.registerCategory()
        PillPreview.startIfRequested()
        MenuPreview.startIfRequested()
    }

    /// Before the meeting folder exists: notification permission (first recording) and the calendar event.
    func willStart() async -> CalendarPick.Event? {
        await finishing?.value
        if !askedNotifications, NotificationRouter.available, !AppModel.shared.options.isTestInstance {
            askedNotifications = true
            Notifier.requestAuthorization()
        }
        return await CalendarService.shared.lookup()
    }

    /// Title for `RecordingLifecycle.begin`: the event's, else nil (date-time placeholder).
    static func title(for event: CalendarPick.Event?) -> String? {
        guard let t = event?.title.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    func didStart(_ s: RecordingSession, event: CalendarPick.Event?) {
        if let event { s.adoptCalendar(attendees: event.attendees, me: event.me) }
        let calendarEnd = event.map { $0.end.timeIntervalSince(s.startedAt) }
        endWatch.begin(meetingID: s.meetingID, startHost: s.startHostTime, calendarEnd: calendarEnd)
        LiveModel.shared.begin(meeting: s.meeting, store: s.store)
        micSilentAnnounced = false
        Announce.post("Recording started: \(s.meeting.title). \(Consent.reminder)")
        if Prefs.notchPillOn {
            let m = PillModel(levels: Self.liveLevels)
            m.title = s.meeting.title
            m.onStop = { AppModel.shared.stop(reason: "pill Stop") }
            pill = m
            lastPillSecond = -1
            NotchPillController.shared.show(model: m)
        }
    }

    /// From the session's 10 Hz tick.
    func tick(_ s: RecordingSession, nowHost: Double, mic: AudioLevel, system: AudioLevel, callAppAudio: Bool) {
        endWatch.tick(nowHost: nowHost, mic: mic, system: system, callAppAudio: callAppAudio)
        if let pill {
            let sec = Int(s.elapsed)
            if sec != lastPillSecond { lastPillSecond = sec; pill.elapsed = s.elapsed }
            let warn = s.warnings.contains(.micSilent)
            if pill.warning != warn { pill.warning = warn }
        }
        let silent = s.warnings.contains(.micSilent)
        if silent != micSilentAnnounced {
            micSilentAnnounced = silent
            Announce.post(silent ? "Warning: no microphone audio for 10 seconds" : "Microphone audio is back")
        }
    }

    /// Hides the pill and flushes the live transcript, then calls `processed` (enqueue). The next
    /// `willStart` waits for this, so a quick restart cannot interleave two meetings in the live engines.
    func didStop(_ s: RecordingSession, then processed: @escaping @MainActor () -> Void) {
        endWatch.end()
        LiveModel.shared.end()
        NotchPillController.shared.hide()
        pill = nil
        Announce.post("Recording stopped. Transcribing \(s.meeting.title)")
        let previous = finishing
        finishing = Task {
            await previous?.value
            await LiveFeed.shared.finish()
            processed()
        }
    }

    /// Waits for the last stop's live flush and enqueue.
    func waitUntilFlushed() async { await finishing?.value }

    /// The display level per stream, read straight from the capture box at frame time; reads the floor
    /// once buffers stop for 0.3 s (`AudioLevel.displayLevel`).
    nonisolated static func liveLevels() -> (Float, Float) {
        let (m, s) = LevelBox.shared.snapshot()
        let now = HostClock.seconds(HostClock.now())
        return (m.displayLevel(now: now), s.displayLevel(now: now))
    }
}

/// Opening a recent meeting: the main window selects it (`AppModel` sets `handler` at launch), else Finder.
@MainActor
enum MeetingOpener {
    static var handler: ((Meeting) -> Void)?

    static func open(_ m: Meeting) {
        if let handler { handler(m) } else { AppModel.shared.reveal(m) }
    }
}
