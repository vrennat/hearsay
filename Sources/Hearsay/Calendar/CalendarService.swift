import EventKit
import Foundation
import HearsayCore
import Observation

/// EventKit adapter for `CalendarPick` (EventKit sees the Google calendar added in Internet Accounts;
/// no Google API client). Access is asked for at the first lookup; a test instance never asks.
@MainActor @Observable
final class CalendarService {
    static let shared = CalendarService()

    private let log = HSLog("calendar")
    private let store = EKEventStore()
    private(set) var current: CalendarPick.Event?
    private var lastLookup: Date?
    private var asked = false
    static let menuLookupInterval: TimeInterval = 60

    private var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    /// Menu open: at most once a minute.
    func refreshForMenu() {
        if let last = lastLookup, Date().timeIntervalSince(last) < Self.menuLookupInterval { return }
        Task { _ = await lookup() }
    }

    /// The event in progress now, asking for access the first time (never for a test instance).
    func lookup(now: Date = Date()) async -> CalendarPick.Event? {
        lastLookup = now
        if !authorized {
            guard !asked, EKEventStore.authorizationStatus(for: .event) == .notDetermined,
                  !AppModel.shared.options.isTestInstance else { current = nil; return nil }
            asked = true
            do {
                let ok = try await store.requestFullAccessToEvents()
                log.info("Calendar access \(ok ? "granted" : "denied")")
                guard ok else { current = nil; return nil }
            } catch {
                log.error("Calendar access request failed: \(error)")
                current = nil
                return nil
            }
        }
        let window = CalendarPick.neighbourWindow
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-window),
                                                 end: now.addingTimeInterval(window), calendars: nil)
        let events = store.events(matching: predicate).map(Self.convert)
        let pick = CalendarPick.current(at: now, in: events)
        if pick?.id != current?.id {
            log.info(pick.map { "Current event: \($0.title) (\($0.attendees.count) guests)" } ?? "No current event among \(events.count)")
        }
        current = pick
        return pick
    }

    static func convert(_ e: EKEvent) -> CalendarPick.Event {
        let guests = e.attendees ?? []
        let mine = guests.first { $0.isCurrentUser }
        let response: CalendarPick.Response
        switch mine?.participantStatus {
        case .accepted?: response = .accepted
        case .declined?: response = .declined
        case .tentative?: response = .tentative
        default: response = .unanswered
        }
        return CalendarPick.Event(
            id: e.calendarItemIdentifier + "@" + String(e.startDate.timeIntervalSince1970),
            calendarID: e.calendar?.calendarIdentifier ?? "",
            title: e.title ?? "",
            start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
            attendees: guests.map(name), includesMe: mine != nil, myResponse: response,
            me: mine.map(name))
    }

    /// Display name, else the address from a `mailto:` URL.
    static func name(_ p: EKParticipant) -> String {
        if let n = p.name, !n.isEmpty { return n }
        let s = p.url.absoluteString
        return s.hasPrefix("mailto:") ? String(s.dropFirst(7)) : s
    }
}
