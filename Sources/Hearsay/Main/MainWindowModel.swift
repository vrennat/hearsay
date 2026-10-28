import AppKit
import HearsayCore
import Observation
import SwiftUI

/// State of the main "Hearsay" window: every meeting in the store, the sidebar search and selection,
/// and the `MeetingModel` of the selected meeting (the detail pane is the old meeting window's view).
@MainActor @Observable
final class MainWindowModel {
    static let shared = MainWindowModel()

    private let log = HSLog("main-window")
    private(set) var meetings: [Meeting] = []
    var search = ""
    var selection: String? { didSet { if selection != oldValue { selectionChanged() } } }
    private(set) var detail: MeetingModel?
    /// Sidebar shown or hidden. Opening the window with nothing selected shows it again: without
    /// it the window is an empty "No Meeting Selected" pane (Tanner).
    var columns: NavigationSplitViewVisibility = .all
    /// The meeting a Delete to Trash confirmation is showing for.
    var pendingDelete: Meeting?
    /// `--preview-main` only: a seeded `recording` meeting stands in for a live session.
    var previewRecordingID: String?

    var recordingID: String? { AppModel.shared.session?.meetingID ?? previewRecordingID }

    var groups: [MeetingList.Group] {
        MeetingList.groups(MeetingList.filter(meetings, query: search), recordingID: recordingID)
    }

    func refresh() {
        meetings = AppModel.shared.store.loadAllMeetings()
        if let s = selection, !meetings.contains(where: { $0.id == s }) { selection = nil }
    }

    func select(_ id: String) {
        if !meetings.contains(where: { $0.id == id }) { refresh() }
        search = ""
        selection = id
        detail?.reload()
    }

    /// The processing queue finished a meeting, or something else rewrote it.
    func reload(_ id: String) {
        refresh()
        if detail?.id == id { detail?.reload() }
    }

    /// Any recording start pauses playback; the recorded meeting's own detail drops its player.
    func recordingStarted(_ id: String) {
        detail?.recordingStarted(id)
        refresh()
    }

    /// The Meetings folder changed: nothing selected belongs to the new store.
    func storeChanged() {
        selection = nil
        refresh()
    }

    private func selectionChanged() {
        guard detail?.id != selection else { return }
        detail?.close()
        detail = selection.flatMap { id in meetings.first { $0.id == id } }
            .map { MeetingModel(meeting: $0, store: AppModel.shared.store) }
    }

    // MARK: Row actions

    func isBusy(_ m: Meeting) -> Bool { m.id == recordingID || AppModel.shared.queue.busy.contains(m.id) }

    func markdownURL(_ m: Meeting) -> URL? {
        let store = AppModel.shared.store
        return store.hasFile(m.id, "transcript.md") ? store.folder(m.id).appendingPathComponent("transcript.md") : nil
    }

    func copyMarkdownPath(_ m: Meeting) {
        guard let url = markdownURL(m) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    /// Moves the meeting's folder to the Trash (recoverable from Finder) and rewrites the index.
    func trash(_ m: Meeting) {
        guard !isBusy(m) else { return }
        let store = AppModel.shared.store
        if selection == m.id { selection = nil }
        do {
            try FileManager.default.trashItem(at: store.folder(m.id), resultingItemURL: nil)
            log.info("Moved \(m.id) to the Trash")
        } catch {
            log.error("Cannot move \(m.id) to the Trash: \(error)")
            NSSound.beep()
        }
        try? IndexRenderer.reindex(store: store)
        refresh()
        AppModel.shared.refreshRecent()
    }
}
