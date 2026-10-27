import Foundation

/// Names to confirm: guesses (voiceprint, invite, known voice) and every name in meetings from before
/// guesses were recorded. Grouped by person so a name used in 17 meetings is one decision. Only
/// confirmed names help recognise voices in other meetings (`KnownVoices`).
public enum NameReview {
    public struct Entry: Sendable, Equatable {
        public var meetingID: String
        public var speaker: String
        public init(meetingID: String, speaker: String) { self.meetingID = meetingID; self.speaker = speaker }
    }

    public struct Person: Sendable, Equatable, Identifiable {
        /// The most used spelling.
        public var name: String
        public var entries: [Entry]
        public var id: String { name.lowercased() }
    }

    /// Unconfirmed names in one meeting, speaker id to name.
    public static func guesses(in meeting: Meeting) -> [String: String] {
        meeting.speakerNames.filter { meeting.nameIsGuess($0.key) && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Everyone with an unconfirmed name, most meetings first. `me`'s first name is left out: your own
    /// voice is matched by the voiceprint, which does not use this.
    public static func pending(store: MeetingStore, me: String? = nil) -> [Person] {
        let mine = me.map { Naming.firstName($0).lowercased() }
        var byKey: [String: [(String, Entry)]] = [:]
        for id in store.listMeetingIDs() {
            guard let m = try? store.loadMeeting(id) else { continue }
            for (speaker, name) in guesses(in: m) where Naming.firstName(name).lowercased() != mine {
                byKey[name.trimmingCharacters(in: .whitespaces).lowercased(), default: []].append((name, Entry(meetingID: id, speaker: speaker)))
            }
        }
        return byKey.map { _, xs in
            var counts: [String: Int] = [:]
            for (n, _) in xs { counts[n, default: 0] += 1 }
            let name = counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }!.key
            return Person(name: name, entries: xs.map(\.1).sorted { ($0.meetingID, $0.speaker) < ($1.meetingID, $1.speaker) })
        }
        .sorted { $0.entries.count != $1.entries.count ? $0.entries.count > $1.entries.count : $0.name < $1.name }
    }

    /// Confirms each entry's name (a meeting whose name changed since is left alone), then reindexes.
    /// Returns how many were confirmed.
    @discardableResult
    public static func confirm(_ entries: [Entry], name: String, store: MeetingStore) throws -> Int {
        var done = 0
        for (id, es) in Dictionary(grouping: entries, by: \.meetingID) {
            var m = try store.loadMeeting(id)
            var changed = false
            for e in es where m.speakerNames[e.speaker]?.caseInsensitiveCompare(name) == .orderedSame && m.nameIsGuess(e.speaker) {
                m.confirmName(e.speaker); changed = true; done += 1
            }
            if changed { try store.saveMeeting(m) }
        }
        if done > 0 { try IndexRenderer.reindex(store: store) }
        return done
    }
}
