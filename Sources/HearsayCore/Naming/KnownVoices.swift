import Foundation

/// People you have named before, recognised by voice in a new meeting. Every speaker with a voice and
/// a typed name in another meeting is a sample for that name on that stream (a call codec changes a
/// voice, so room samples only match room voices and call samples call voices).
public enum KnownVoices {
    /// Stricter than your own voiceprint (0.6): a wrong name on someone else reads as fact. Your voice
    /// measured 0.70 to 0.90 against itself and other voices 0.54 or less; not yet measured for call audio.
    public static let threshold: Float = 0.65
    /// The best name must beat the next name by this much, and the next voice in the meeting by this much.
    public static let margin: Float = 0.15

    public struct Sample: Sendable, Equatable {
        public var name: String
        public var stream: StreamKind
        public var voice: [Float]
        /// The meeting it came from, so one snapshot can serve every meeting of a backfill run.
        public var meetingID: String
        public init(name: String, stream: StreamKind, voice: [Float], meetingID: String = "") {
            self.name = name; self.stream = stream; self.voice = voice; self.meetingID = meetingID
        }
    }

    /// A name needs samples from at least this many meetings: one mislabelled sample cannot name anyone.
    public static let minSamples = 2

    /// One sample per speaker you named (typed, live or after) with a voice, in every other meeting.
    /// Guessed and unconfirmed old names (`Meeting.nameIsConfirmed`) are skipped so a wrong guess cannot spread.
    public static func samples(store: MeetingStore, excluding id: String? = nil) -> [Sample] {
        store.listMeetingIDs().filter { $0 != id }.flatMap { other -> [Sample] in
            guard let m = try? store.loadMeeting(other), let t = try? store.loadTranscript(other) else { return [] }
            return t.speakers.compactMap { s in
                guard let v = s.voice, m.nameIsConfirmed(s.id),
                      let n = m.speakerNames[s.id]?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return nil }
                return Sample(name: n, stream: s.stream, voice: v, meetingID: other)
            }
        }
    }

    /// Speaker id to name for `eligible` speakers whose voice clearly matches one known name. All of
    /// `speakers` take part in the ambiguity check: a name is withheld when any other voice in the
    /// meeting on the same stream scores within `margin` of the best, whether or not it is eligible.
    /// `taken` are names already used in this meeting, compared by first name.
    public static func match(speakers: [Speaker], samples: [Sample], taken: Set<String>, eligible: Set<String>? = nil) -> [String: String] {
        let takenKeys = Set(taken.map { Naming.firstName($0).lowercased() })
        var spelling: [String: [String: Int]] = [:]
        for s in samples { spelling[s.name.lowercased(), default: [:]][s.name, default: 0] += 1 }
        // Raw scores, no threshold: speaker id -> name key -> best cosine on the same stream.
        var scores: [String: [String: Float]] = [:]
        for sp in speakers {
            guard let v = sp.voice else { continue }
            var byName: [String: [Float]] = [:]
            for s in samples where s.stream == sp.stream { byName[s.name.lowercased(), default: []].append(VoiceEmbedder.cosine(v, s.voice)) }
            scores[sp.id] = byName.filter { $0.value.count >= minSamples }.mapValues { $0.max() ?? -1 }
        }
        let streamOf = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0.stream) })
        var out: [String: String] = [:]
        var used = Set<String>()
        for sp in speakers where eligible?.contains(sp.id) ?? true {
            guard let mine = scores[sp.id] else { continue }
            let ranked = mine.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            guard let top = ranked.first, top.value >= threshold else { continue }
            if ranked.count > 1, top.value - ranked[1].value < margin { continue }
            let key = top.key
            guard !takenKeys.contains(Naming.firstName(key)), !used.contains(key) else { continue }
            let rival = scores.filter { $0.key != sp.id && streamOf[$0.key] == sp.stream }.compactMap { $0.value[key] }.max() ?? -1
            guard top.value - rival >= margin else { continue }
            used.insert(key)
            out[sp.id] = spelling[key]?.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? key
        }
        return out
    }
}
