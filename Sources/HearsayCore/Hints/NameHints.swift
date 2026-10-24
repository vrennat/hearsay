import Foundation

/// Name hints from how people address each other (spec, Naming aids). Suggestions only; nothing here
/// writes a name.
///
/// - "Hey Nate, how's it going?" or "what's next up, Priya?" points at the next voice: the first other
///   speaker among the next 3 turns that starts within 4 s of the cue turn's end.
/// - "Thanks, Omar." points at the voice before: the nearest other speaker among the previous 3 turns
///   that ended within 4 s of the cue turn's start.
/// - A cue counts only right after a greeting or thanks that starts its sentence, or set off by a comma
///   and ending a question or the turn; never with retold-speech words in the 4 words before it.
/// - Most votes win, then first heard.
public enum NameHints {
    public struct Hint: Sendable, Equatable {
        public let speaker: String
        public let name: String
        public let quote: String
        /// Start of the turn holding the cue, in meeting seconds.
        public let at: Double
        public let votes: Int
    }

    public static let lookTurns = 3
    public static let maxGapSeconds = 4.0
    static let greetings: [[String]] = [
        ["good", "morning"], ["good", "afternoon"], ["good", "evening"],
        ["hey"], ["hi"], ["hello"], ["morning"], ["welcome"], ["yo"], ["howdy"],
    ]
    static let thanks: [[String]] = [["thank", "you"], ["thanks"], ["cheers"]]
    static let retold: Set<String> = ["said", "says", "say", "like", "told", "tells", "tell", "asked", "asks"]

    struct Turn { let speaker: String; let start: Double; let end: Double; let text: String }
    enum Direction { case next, previous }

    /// Capitalized first names from the invite plus names typed in any meeting.
    public static func candidates(attendees: [String], typedNames: [String]) -> Set<String> {
        var out = Set<String>()
        for full in attendees + typedNames {
            guard let first = full.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { continue }
            let w = String(first).trimmingCharacters(in: .punctuationCharacters)
            guard w.count >= 2, let c = w.first, w.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" }) else { continue }
            out.insert(c.uppercased() + w.dropFirst())
        }
        return out
    }

    /// Candidates for a meeting in a store: its attendees plus every name typed in any meeting.
    public static func candidates(for meeting: Meeting, store: MeetingStore) -> Set<String> {
        let typed = store.loadAllMeetings().flatMap { Array($0.speakerNames.values) }
            + ((try? store.listMeetingIDs().compactMap { try store.loadLive($0) }.flatMap { Array($0.speakerNames.values) }) ?? [])
        return candidates(attendees: meeting.attendees, typedNames: typed)
    }

    /// One hint per speaker that drew at least one cue.
    public static func hints(utterances: [Utterance], candidates: Set<String>) -> [Hint] {
        let turns = makeTurns(utterances)
        struct Vote { var count = 0; var first: Double; var quote: String; var at: Double }
        var votes: [String: [String: Vote]] = [:]  // speaker -> name -> vote
        for (k, turn) in turns.enumerated() {
            let sentences = splitSentences(turn.text)
            for (si, sentence) in sentences.enumerated() {
                for (name, direction) in cues(in: sentence, isLastOfTurn: si == sentences.count - 1, candidates: candidates) {
                    guard let target = target(turns, k, direction) else { continue }
                    var v = votes[target, default: [:]][name] ?? Vote(first: turn.start, quote: sentence, at: turn.start)
                    v.count += 1
                    votes[target, default: [:]][name] = v
                }
            }
        }
        return votes.compactMap { speaker, byName -> Hint? in
            guard let best = byName.max(by: { a, b in
                a.value.count != b.value.count ? a.value.count < b.value.count : a.value.first > b.value.first
            }) else { return nil }
            return Hint(speaker: speaker, name: best.key, quote: best.value.quote, at: best.value.at, votes: best.value.count)
        }.sorted { $0.at < $1.at }
    }

    static func makeTurns(_ utterances: [Utterance]) -> [Turn] {
        var turns: [Turn] = []
        for u in utterances.sorted(by: { $0.start < $1.start }) {
            if let last = turns.last, last.speaker == u.speaker {
                turns[turns.count - 1] = Turn(speaker: u.speaker, start: last.start, end: max(last.end, u.end), text: last.text + " " + u.text)
            } else {
                turns.append(Turn(speaker: u.speaker, start: u.start, end: u.end, text: u.text))
            }
        }
        return turns
    }

    static func target(_ turns: [Turn], _ k: Int, _ direction: Direction) -> String? {
        let me = turns[k].speaker
        switch direction {
        case .next:
            for j in (k + 1)..<min(turns.count, k + 1 + lookTurns) where turns[j].speaker != me {
                return turns[j].start - turns[k].end <= maxGapSeconds ? turns[j].speaker : nil
            }
        case .previous:
            for j in stride(from: k - 1, through: max(0, k - lookTurns), by: -1) where j >= 0 && turns[j].speaker != me {
                return turns[k].start - turns[j].end <= maxGapSeconds ? turns[j].speaker : nil
            }
        }
        return nil
    }

    static func splitSentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "?" || ch == "!" {
                let s = current.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { out.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    static func bare(_ token: Substring) -> String {
        String(token).trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    /// Names addressed in one sentence with the direction each points.
    static func cues(in sentence: String, isLastOfTurn: Bool, candidates: Set<String>) -> [(String, Direction)] {
        let tokens = sentence.split(separator: " ", omittingEmptySubsequences: true)
        let lower = tokens.map { bare($0).lowercased() }
        let opener: (length: Int, direction: Direction)? = {
            for g in thanks where lower.starts(with: g) { return (g.count, .previous) }
            for g in greetings where lower.starts(with: g) { return (g.count, .next) }
            return nil
        }()
        var out: [(String, Direction)] = []
        for (i, token) in tokens.enumerated() {
            let word = bare(token)
            guard candidates.contains(word), word.first?.isUppercase == true else { continue }
            let before = lower[max(0, i - 4)..<i]
            if before.contains(where: retold.contains) { continue }
            if let opener, i == opener.length {
                out.append((word, opener.direction)); continue
            }
            let setOff = i > 0 && tokens[i - 1].hasSuffix(",")
            let endsSentence = i == tokens.count - 1
            if setOff && endsSentence && (sentence.hasSuffix("?") || isLastOfTurn) {
                out.append((word, .next))
            }
        }
        return out
    }
}
