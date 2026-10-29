import Foundation

/// Speaker naming in spec priority order (step 7): names already in `meeting.json`; live names;
/// then the voiceprint and the invite; then voices named in other meetings (`KnownVoices`) fill
/// speakers still unnamed, always with names not already used.
public enum Naming {
    public struct Input: Sendable {
        public var speakers: [Speaker]
        public var existing: [String: String]
        /// Live names already mapped to final speaker ids (`LiveNameMapper`).
        public var live: [String: String]
        /// Your name: `meeting.me`, else the app setting or `--me`. Nil skips the voiceprint and 1:1 rules.
        public var me: String?
        public var attendees: [String]
        public var title: String
        public var voiceprintSamples: [[Float]]
        /// Named voices from other meetings (`KnownVoices.samples`), for everyone else.
        public var knownVoices: [KnownVoices.Sample]

        public init(speakers: [Speaker], existing: [String: String] = [:], live: [String: String] = [:], me: String?,
                    attendees: [String] = [], title: String = "", voiceprintSamples: [[Float]] = [],
                    knownVoices: [KnownVoices.Sample] = []) {
            self.speakers = speakers; self.existing = existing; self.live = live; self.me = me
            self.attendees = attendees; self.title = title; self.voiceprintSamples = voiceprintSamples
            self.knownVoices = knownVoices
        }
    }

    public struct Output: Sendable, Equatable {
        public var names: [String: String]
        /// The speaker that is you (voiceprint, an existing name, or the 1:1 one-mic-voice rule).
        public var me: String?
        /// Speakers this run named by guessing (voiceprint, invite, known voice), not from typed or live names.
        public var inferred: Set<String> = []
    }

    public static func name(_ input: Input) -> Output {
        let ids = Set(input.speakers.map(\.id))
        var names = input.existing.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        // A guess is compared by first name ("Jordan Kim" from the invite and "Jordan" from a known voice
        // are one person); typed and live names only by the whole name, since two real Alexes happen.
        func used(_ n: String, byFirstName: Bool) -> Bool {
            names.values.contains { byFirstName ? firstName($0).lowercased() == firstName(n).lowercased()
                                                : $0.caseInsensitiveCompare(n) == .orderedSame }
        }
        var inferred = Set<String>()
        func fill(_ id: String, _ n: String, guessed: Bool = true) {
            guard ids.contains(id), names[id] == nil, !used(n, byFirstName: guessed) else { return }
            names[id] = n
            if guessed { inferred.insert(id) }
        }

        for (id, n) in input.live.sorted(by: { $0.key < $1.key }) { fill(id, n, guessed: false) }

        let main = mainSpeakers(input.speakers)
        let myFirst = input.me.map(firstName).flatMap { $0.isEmpty ? nil : $0 }
        var meID: String?
        if let myFirst {
            meID = input.speakers.first { s in s.stream == .mic && names[s.id].map { firstName($0).lowercased() } == myFirst.lowercased() }?.id
            if meID == nil { meID = Voiceprint.match(speakers: input.speakers, samples: input.voiceprintSamples) }
            let others = input.attendees.filter { firstName($0).lowercased() != myFirst.lowercased() }
            let oneOnOne = others.count == 1
            let mainMic = main.filter { $0.stream == .mic }
            if oneOnOne, meID == nil, mainMic.count == 1 { meID = mainMic[0].id }
            if let meID { fill(meID, myFirst) }
            if oneOnOne {
                let candidates = main.filter { $0.id != meID }
                if candidates.count == 1 { fill(candidates[0].id, displayName(others[0], title: input.title)) }
            }
        }
        // Your own name is the voiceprint's job, so it is never handed out by voice here.
        let others = input.speakers.filter { names[$0.id] == nil && $0.id != meID }
        let taken = Set(names.values).union(myFirst.map { [$0] } ?? [])
        let mine = myFirst?.lowercased()
        let known = input.knownVoices.filter { firstName($0.name).lowercased() != mine }
        // Every voice in the meeting takes part in the ambiguity check, named or not.
        for (id, n) in KnownVoices.match(speakers: input.speakers, samples: known, taken: taken,
                                         eligible: Set(others.map(\.id))) { fill(id, n) }
        return Output(names: names, me: meID, inferred: inferred)
    }

    /// Speakers with at least 5% of their stream's talk time.
    public static func mainSpeakers(_ speakers: [Speaker]) -> [Speaker] {
        var total: [StreamKind: Double] = [:]
        for s in speakers { total[s.stream, default: 0] += s.talkSeconds }
        return speakers.filter { s in
            let t = total[s.stream] ?? 0
            return t > 0 && s.talkSeconds / t >= SpeakerSummary.mainShare
        }
    }

    /// First word of a name; an email address gives its local part up to a dot, capitalised.
    public static func firstName(_ name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespaces)
        if let at = s.firstIndex(of: "@") {
            s = String(s[..<at]).components(separatedBy: CharacterSet(charactersIn: "._")).first ?? ""
            return s.prefix(1).uppercased() + s.dropFirst()
        }
        return s.split(separator: " ").first.map(String.init) ?? ""
    }

    /// First name, or a title word of 3+ letters that starts it ("Rob / Tanner" names Robert "Rob").
    public static func displayName(_ attendee: String, title: String) -> String {
        let first = firstName(attendee)
        let words = title.split { !$0.isLetter }.map(String.init)
        if let nick = words.first(where: { $0.count >= 3 && $0.count < first.count && first.lowercased().hasPrefix($0.lowercased()) }) {
            return nick.prefix(1).uppercased() + nick.dropFirst()
        }
        return first
    }
}
