import Foundation

/// The two after-the-fact edits, shared by `hearsay rename` / `hearsay title` and the meeting window.
public enum MeetingEdits {
    /// Names a speaker (an empty name clears it), saves `meeting.json`, re-renders and reindexes.
    @discardableResult
    public static func rename(id: String, speaker: String, name: String, store: MeetingStore) throws -> String {
        var m = try store.loadMeeting(id)
        let n = name.trimmingCharacters(in: .whitespaces)
        m.speakerNames[speaker] = n.isEmpty ? nil : n
        try store.saveMeeting(m)
        try IndexRenderer.reindex(store: store)
        return n
    }

    /// Sets the title the user typed (a placeholder becomes the date-time title), marks it
    /// `titleEditedByUser` so the on-device titler never replaces it, saves, re-renders and reindexes.
    /// The folder name never changes.
    @discardableResult
    public static func setTitle(id: String, title: String, store: MeetingStore) throws -> String {
        var m = try store.loadMeeting(id)
        m.title = title
        m.title = Titler.title(for: m)
        m.titleEditedByUser = true
        try store.saveMeeting(m)
        try IndexRenderer.reindex(store: store)
        return m.title
    }

    /// Writes a title proposed by `TitleGenerator` (`hearsay title <id> --apply`). Leaves
    /// `titleEditedByUser` as it was: the text came from the model, not the user's typing.
    @discardableResult
    public static func applyGeneratedTitle(id: String, title: String, store: MeetingStore) throws -> String {
        var m = try store.loadMeeting(id)
        m.title = title
        try store.saveMeeting(m)
        try IndexRenderer.reindex(store: store)
        return m.title
    }
}
