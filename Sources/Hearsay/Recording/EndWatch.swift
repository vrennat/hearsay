import Foundation
import HearsayCore
@preconcurrency import UserNotifications

/// Feeds `EndDetector` from the session's 10 Hz tick and posts "Meeting over?" with Stop / Keep going.
/// Inputs, all in meeting-time seconds: each stream's last loud (> -46 dBFS) buffer, whether a call app
/// holds the mic (`CallAppMonitor.callAppAudio`), and the calendar event's end.
@MainActor
final class EndWatch {
    static let category = "meeting-over"
    static let stopAction = "stop"
    static let keepAction = "keep-going"
    static let requestID = "meeting-over"

    private let log = HSLog("end")
    private var detector = EndDetector()
    private var startHostSeconds: Double = 0
    private var lastMicLoud: Double?
    private var lastSystemLoud: Double?
    private var callAudio: Bool?
    private var meetingID: String?

    static func registerCategory() {
        let stop = UNNotificationAction(identifier: stopAction, title: "Stop", options: [])
        let keep = UNNotificationAction(identifier: keepAction, title: "Keep going", options: [])
        let cat = UNNotificationCategory(identifier: category, actions: [stop, keep], intentIdentifiers: [], options: [])
        NotificationRouter.shared.register(cat) { action, request in
            let id = request.content.userInfo["meetingID"] as? String
            guard action == stopAction else { return }
            guard let s = AppModel.shared.session, (id ?? "").isEmpty || s.meetingID == id else { return }
            AppModel.shared.stop(reason: "Meeting over? -> Stop")
        }
    }

    func begin(meetingID: String, startHost: UInt64, calendarEnd: Double?) {
        self.meetingID = meetingID
        detector = EndDetector()
        startHostSeconds = HostClock.seconds(startHost)
        lastMicLoud = nil; lastSystemLoud = nil; callAudio = nil
        _ = detector.handle(.calendarEnd(calendarEnd))
        if let calendarEnd { log.info("Calendar end at \(Int(calendarEnd)) s of meeting time") }
    }

    func tick(nowHost: Double, mic: AudioLevel, system: AudioLevel, callAppAudio: Bool) {
        let now = nowHost - startHostSeconds
        var prompt: EndDetector.Prompt?
        func feed(_ e: EndDetector.Event) { if let p = detector.handle(e) { prompt = p } }
        if let t = mic.lastLoudAt.map({ $0 - startHostSeconds }), t != lastMicLoud { lastMicLoud = t; feed(.micLoud(t)) }
        if let t = system.lastLoudAt.map({ $0 - startHostSeconds }), t != lastSystemLoud { lastSystemLoud = t; feed(.systemLoud(t)) }
        if callAppAudio != callAudio { callAudio = callAppAudio; feed(.callAppAudio(present: callAppAudio, at: now)) }
        feed(.tick(now))
        if let prompt { post(prompt) }
    }

    func end() {
        meetingID = nil
        if NotificationRouter.available {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.requestID])
        }
    }

    private func post(_ p: EndDetector.Prompt) {
        let body: String
        switch p.reason {
        case .callEnded: body = "The call app has gone quiet."
        case .calendarEnded: body = "The calendar event has ended and it's been quiet for a minute."
        case .silence: body = "Nothing heard for 5 minutes."
        }
        log.info("Meeting over? (\(p.reason.rawValue) at \(Int(p.at)) s)")
        Announce.post("Meeting over? \(body) Still recording.")
        guard NotificationRouter.available else { return }
        let content = UNMutableNotificationContent()
        content.title = "Meeting over?"
        content.body = body + " Still recording."
        content.categoryIdentifier = Self.category
        content.userInfo = ["meetingID": meetingID ?? ""]
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.requestID, content: content, trigger: nil))
    }
}
