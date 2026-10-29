import Foundation

/// The pure half of meeting titling (spec amendment "Meeting titles come from the on-device LLM"):
/// which titles need the model, what the model is told, and whether its answer is acceptable.
public enum TitleRules {
    public static let minWords = 3
    public static let maxWords = 8
    /// Transcript words handed to the model.
    public static let excerptWords = 1_500

    // MARK: Generic titles

    /// Calendar titles that say nothing about the meeting, after `normalize` and dropping `modifiers`.
    static let genericTitles: Set<String> = [
        "sync", "sync up", "1 1", "1 on 1", "one on one", "catch up", "catchup", "call", "chat", "check in",
        "checkin", "touch base", "huddle", "meeting", "meet", "connect", "discussion", "talk", "standup",
        "stand up", "call with", "meeting with", "sync with", "chat with", "catch up with", "video call",
        "phone call", "zoom", "google meet", "teams", "facetime",
    ]
    /// Words that do not make a generic title specific ("Weekly Sync", "Quick Call").
    static let modifiers: Set<String> = [
        "a", "the", "our", "quick", "short", "weekly", "daily", "biweekly", "monthly", "team", "regular",
        "recurring", "and", "with", "x", "vs",
    ]

    /// Lowercased, every run of non-alphanumerics replaced by one space ("1:1" -> "1 1").
    static func normalize(_ s: String) -> String {
        let spaced = String(s.lowercased().map { (c: Character) -> Character in c.isLetter || c.isNumber ? c : " " })
        return spaced.split(separator: " ").joined(separator: " ")
    }

    /// First-name and full-name tokens of everyone the meeting knows about, lowercased.
    static func nameTokens(_ names: [String]) -> Set<String> {
        Set(names.flatMap { normalize($0).split(separator: " ").map(String.init) }.filter { $0.count > 1 })
    }

    /// The title the recorder writes before a calendar title is known ("Meeting Oct 23 09:30") or
    /// `Titler.dateTimeTitle` ("2026-10-23 09:30 Meeting").
    static func isDatePlaceholder(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces)
        return t.range(of: #"^Meeting [A-Z][a-z]{2} \d{1,2} \d{1,2}:\d{2}$"#, options: .regularExpression) != nil
            || t.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2} Meeting$"#, options: .regularExpression) != nil
    }

    /// True when the title is empty, a placeholder, a date-time placeholder, or generic: once modifier
    /// words and people's names are dropped, nothing is left or only a generic word ("Sync",
    /// "Weekly 1:1", "Rob / Tanner", "Catch up with Priya").
    public static func isGeneric(_ title: String, names: [String] = []) -> Bool {
        if Titler.isPlaceholder(title) || isDatePlaceholder(title) { return true }
        let n = normalize(title)
        if n.isEmpty || genericTitles.contains(n) { return true }
        let people = nameTokens(names)
        let rest = n.split(separator: " ").map(String.init).filter { !modifiers.contains($0) && !people.contains($0) }
        let joined = rest.joined(separator: " ")
        return rest.isEmpty || genericTitles.contains(joined)
    }

    /// Everyone whose name could appear: attendees, `me`, typed speaker names.
    public static func knownNames(_ meeting: Meeting) -> [String] {
        meeting.attendees + [meeting.me].compactMap { $0 } + Array(meeting.speakerNames.values)
    }

    /// Whether the pipeline should ask the model: never for a hand-typed title; otherwise only when the
    /// current title is generic.
    public static func needsGeneration(_ meeting: Meeting) -> Bool {
        !meeting.titleEditedByUser && isGeneric(meeting.title, names: knownNames(meeting))
    }

    // MARK: Prompt

    public static let instructions = """
        You write a short title for a recorded meeting, from its calendar details and the start of its \
        transcript. The title names the topic: what was discussed or decided. Rules: 3 to 8 words; Title \
        Case; no date, weekday or time; no quotation marks; no punctuation at the end; do not use the word \
        "Meeting"; never just a person's name. Output only the title.
        """

    /// The prompt: calendar title (only when it is a real calendar title, not a recorder placeholder),
    /// attendees, date, duration, speaker names, then the first `excerptWords` words of the transcript
    /// (cleaned text when `cleanup` matches) as `Name: text` lines.
    public static func prompt(meeting: Meeting, transcript: Transcript, cleanup: Cleanup?,
                              timeZone: TimeZone = .current) -> String {
        var out: [String] = []
        let t = meeting.title.trimmingCharacters(in: .whitespaces)
        if !Titler.isPlaceholder(t), !isDatePlaceholder(t) { out.append("Calendar title: \(t)") }
        if !meeting.attendees.isEmpty { out.append("Attendees: \(meeting.attendees.joined(separator: ", "))") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        out.append("Date: \(f.string(from: meeting.startedAt))")
        let duration = meeting.duration ?? transcript.utterances.map(\.end).max()
        if let d = duration { out.append("Duration: \(max(1, Int((d / 60).rounded()))) min") }

        let label: (String) -> String = { id in
            if let n = meeting.speakerNames[id], !n.isEmpty { return n }
            return transcript.speaker(id)?.defaultLabel ?? id
        }
        let speakers = transcript.speakers.sorted { $0.talkSeconds > $1.talkSeconds }.map { label($0.id) }
        if !speakers.isEmpty { out.append("Speakers: \(speakers.joined(separator: ", "))") }

        var texts = transcript.utterances.map(\.text)
        if let cleanup, cleanup.matches(transcript) {
            for c in cleanup.utterances where texts.indices.contains(c.index) { texts[c.index] = c.text }
        }
        var lines: [String] = []
        var left = excerptWords
        for (i, u) in transcript.utterances.enumerated() where left > 0 {
            let words = texts[i].split(whereSeparator: \.isWhitespace)
            guard !words.isEmpty else { continue }
            let kept = words.prefix(left)
            left -= kept.count
            lines.append("\(label(u.speaker)): \(kept.joined(separator: " "))")
        }
        out.append("")
        out.append("Transcript (start):")
        out += lines
        return out.joined(separator: "\n")
    }

    // MARK: Validation

    /// Words that stay lowercase inside a Title Case title.
    static let smallWords: Set<String> = [
        "a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "into", "nor", "of", "on", "or", "per",
        "the", "to", "vs", "via", "with", "over", "up",
    ]
    static let dateWords: Set<String> = [
        "january", "february", "march", "april", "june", "july", "august", "september", "october",
        "november", "december", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov",
        "dec", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "today",
        "tomorrow", "yesterday",
    ]

    public enum Rejection: Error, Equatable, Sendable, CustomStringConvertible {
        case wordCount(Int), notTitleCase(String), quotes, trailingPunctuation, date, meetingFiller, nameOnly, generic
        public var description: String {
            switch self {
            case .wordCount(let n): return "\(n) words, need \(TitleRules.minWords) to \(TitleRules.maxWords)"
            case .notTitleCase(let w): return "not Title Case (\"\(w)\")"
            case .quotes: return "contains quotation marks"
            case .trailingPunctuation: return "ends with punctuation"
            case .date: return "contains a date"
            case .meetingFiller: return "uses \"Meeting\" filler"
            case .nameOnly: return "only a person's name"
            case .generic: return "generic"
            }
        }
    }

    /// Trims whitespace, and only whitespace: everything else the rules forbid is a rejection, so a
    /// bad answer falls back instead of being patched into something the model did not say.
    public static func validate(_ raw: String, names: [String] = []) -> Result<String, Rejection> {
        let title = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let words = title.split(separator: " ").map(String.init)
        guard (minWords...maxWords).contains(words.count) else { return .failure(.wordCount(words.count)) }
        if title.contains(where: { "\"“”„«»`".contains($0) }) || words.contains(where: { $0.hasPrefix("'") || $0.hasSuffix("'") || $0.hasPrefix("‘") || $0.hasSuffix("’") }) {
            return .failure(.quotes)
        }
        if let last = title.last, !(last.isLetter || last.isNumber || last == ")") { return .failure(.trailingPunctuation) }
        let tokens = normalize(title).split(separator: " ").map(String.init)
        if tokens.contains(where: dateWords.contains)
            || title.range(of: #"\b(19|20)\d{2}\b|\b\d{1,2}/\d{1,2}\b|\b\d{1,2}(st|nd|rd|th)\b|\b\d{1,2}:\d{2}\b"#, options: .regularExpression) != nil {
            return .failure(.date)
        }
        if tokens.contains("meeting") || tokens.contains("meetings") { return .failure(.meetingFiller) }
        for (i, w) in words.enumerated() {
            guard let first = w.first(where: { $0.isLetter }) else { continue }
            let bare = w.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if i > 0, smallWords.contains(bare) { continue }
            if !first.isUppercase { return .failure(.notTitleCase(w)) }
        }
        let people = nameTokens(names)
        let rest = tokens.filter { !modifiers.contains($0) && !people.contains($0) }
        if rest.isEmpty { return .failure(.nameOnly) }
        if isGeneric(title, names: names) { return .failure(.generic) }
        return .success(title)
    }
}
