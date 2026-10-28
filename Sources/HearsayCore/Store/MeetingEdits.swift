import Foundation

/// The two after-the-fact edits, shared by `hearsay rename` / `hearsay title` and the meeting window.
public enum MeetingEdits {
    /// Names a speaker (an empty name clears it), saves `meeting.json`, re-renders and reindexes.
    @discardableResult
    public static func rename(id: String, speaker: String, name: String, store: MeetingStore) throws -> String {
        var m = try store.loadMeeting(id)
        let n = name.trimmingCharacters(in: .whitespaces)
        m.speakerNames[speaker] = n.isEmpty ? nil : n
        if !n.isEmpty { m.confirmName(speaker) }
        try store.saveMeeting(m)
        try IndexRenderer.reindex(store: store)
        return n
    }

    /// Moves utterances to another speaker on the same stream, or (`to` nil) to a new one, for lines
    /// diarization put on the wrong voice (a quiet person inside someone else's turns). Text, order and
    /// `processedAt` stay, so `cleanup.json` still applies. Talk times are recomputed, a speaker left
    /// with no lines is removed with its name, and the new speaker has no voice (reprocessing or
    /// `voices` gives it one; reprocessing also redoes the split and drops these moves).
    /// Returns the speaker the lines now belong to.
    @discardableResult
    public static func reassign(id: String, utterances indices: [Int], to target: String?, store: MeetingStore) throws -> String {
        guard var t = try store.loadTranscript(id) else { throw EditError.noTranscript }
        var m = try store.loadMeeting(id)
        let valid = indices.filter { t.utterances.indices.contains($0) }
        guard let first = valid.first else { throw EditError.noSuchLine }
        let stream = t.utterances[first].stream
        guard valid.allSatisfy({ t.utterances[$0].stream == stream }) else { throw EditError.mixedStreams }
        let dest: String
        if let target {
            guard let s = t.speaker(target), s.stream == stream else { throw EditError.wrongStream }
            dest = s.id
        } else {
            let prefix = stream == .mic ? "mic" : "sys"
            let n = (t.speakers.filter { $0.stream == stream }.compactMap { Int($0.id.split(separator: "-").last ?? "") }.max() ?? 0) + 1
            dest = "\(prefix)-\(n)"
            t.speakers.append(Speaker(id: dest, stream: stream, defaultLabel: Attribution.defaultLabel(stream: stream, number: n), talkSeconds: 0))
        }
        for i in valid { t.utterances[i].speaker = dest }
        var talk: [String: Double] = [:]
        for u in t.utterances { talk[u.speaker, default: 0] += u.end - u.start }
        t.speakers = t.speakers.compactMap { s in
            guard let secs = talk[s.id], secs > 0 else { return nil }
            var s = s; s.talkSeconds = secs; return s
        }
        let kept = Set(t.speakers.map(\.id))
        m.speakerNames = m.speakerNames.filter { kept.contains($0.key) }
        m.inferredSpeakers = m.inferredSpeakers?.filter { kept.contains($0) }
        m.confirmedSpeakers = m.confirmedSpeakers.filter { kept.contains($0) }
        try store.saveTranscript(t, id: id)
        try store.saveMeeting(m)
        try IndexRenderer.reindex(store: store)
        return dest
    }

    public enum EditError: Error, CustomStringConvertible {
        case noTranscript, noSuchLine, mixedStreams, wrongStream
        public var description: String {
            switch self {
            case .noTranscript: "This meeting has no transcript yet."
            case .noSuchLine: "That line no longer exists."
            case .mixedStreams: "Room and call lines cannot be moved together."
            case .wrongStream: "Lines can only move to a speaker on the same side (room or call)."
            }
        }
    }

    /// How many people spoke on the call (nil: let the diarizer decide). Takes effect when the
    /// meeting is next processed.
    public static func setCallSpeakers(id: String, count: Int?, store: MeetingStore) throws {
        var m = try store.loadMeeting(id)
        m.callSpeakers = count.flatMap { $0 > 1 ? $0 : nil }
        try store.saveMeeting(m)
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
