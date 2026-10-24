import AppKit
import Foundation
import HearsayCore

/// The user-chosen Meetings folder: a security-scoped bookmark in `meetingsFolderBookmark`, default
/// `~/Meetings`. The scope is held while that folder is the app's store (the store is used all the
/// time: recording, processing, retention) and released when the folder changes or the app quits.
@MainActor
enum MeetingsFolder {
    static let bookmarkKey = "meetingsFolderBookmark"
    private static let log = HSLog("folder")
    private static var accessing: URL?

    /// The saved folder (scope started), else nil for the default.
    static func resolveSaved() -> URL? {
        guard let data = Prefs.defaults.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            begin(url)
            if stale { try? save(url) }
            return url
        } catch {
            log.error("Saved Meetings folder bookmark does not resolve (\(error)); using ~/Meetings")
            return nil
        }
    }

    /// Saves `url` as the Meetings folder and moves the held scope to it.
    static func save(_ url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        Prefs.defaults.set(data, forKey: bookmarkKey)
        begin(url)
    }

    static func end() {
        accessing?.stopAccessingSecurityScopedResource()
        accessing = nil
    }

    private static func begin(_ url: URL) {
        guard accessing?.standardizedFileURL != url.standardizedFileURL else { return }
        end()
        // Returns false outside the sandbox, where no scope is needed; the folder is still usable.
        if url.startAccessingSecurityScopedResource() { accessing = url }
    }

    /// Folder picker. Returns the chosen folder or nil.
    static func choose(current: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = current
        panel.prompt = "Use Folder"
        panel.message = "Choose where Hearsay keeps meeting folders."
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }
}
