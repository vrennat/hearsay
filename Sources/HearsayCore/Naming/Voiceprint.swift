import Foundation

/// Your voice, built on the fly from mic speakers named with your first name in other meetings
/// (spec step 7). Measured on 15 meetings: you scored 0.70 to 0.90, other mic voices 0.54 or less.
public enum Voiceprint {
    public static let threshold: Float = 0.6
    public static let margin: Float = 0.15

    /// One sample per other meeting: its mic speaker with a voice named `firstName` (the one with
    /// the most talk time if several are).
    public static func samples(store: MeetingStore, firstName: String, excluding id: String) -> [[Float]] {
        let key = firstName.lowercased()
        return store.listMeetingIDs().filter { $0 != id }.compactMap { other in
            guard let m = try? store.loadMeeting(other), let t = try? store.loadTranscript(other) else { return nil }
            return t.speakers
                .filter { s in s.stream == .mic && s.voice != nil && m.speakerNames[s.id].map { Naming.firstName($0).lowercased() } == key }
                .max { $0.talkSeconds < $1.talkSeconds }?.voice
        }
    }

    /// The mic speaker that is you: best cosine against any sample at 0.6+ and 0.15 ahead of the next
    /// mic voice. Only voices with an embedding take part.
    public static func match(speakers: [Speaker], samples: [[Float]]) -> String? {
        guard !samples.isEmpty else { return nil }
        let scored = speakers.filter { $0.stream == .mic }.compactMap { s -> (String, Float)? in
            guard let v = s.voice else { return nil }
            return (s.id, samples.map { VoiceEmbedder.cosine(v, $0) }.max() ?? -1)
        }.sorted { $0.1 > $1.1 }
        guard let best = scored.first, best.1 >= threshold else { return nil }
        if scored.count > 1, best.1 - scored[1].1 < margin { return nil }
        return best.0
    }
}
