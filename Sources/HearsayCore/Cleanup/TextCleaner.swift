import Foundation

/// Filler and repeat removal, in code (spec step 5: the on-device model got about 3 of 114 fixes
/// right and swapped glossary names in, so it is not used).
///
/// Conservative on purpose: only the fillers below, and only back-to-back repeats of one word or one
/// two-word phrase with no punctuation between the copies. "Like" and "you know" are not removed:
/// they are often real words.
public enum TextCleaner {
    public static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "ah", "hmm", "hm", "mm"]
    public static let method = "hearsay"

    public static func clean(_ text: String) -> String {
        var tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        tokens = removeFillers(tokens)
        tokens = removeRepeats(tokens)
        return tokens.joined(separator: " ")
    }

    /// `cleanup.json` for a transcript, one entry per utterance (index into `utterances`).
    public static func cleanup(for transcript: Transcript, now: Date = Date()) -> Cleanup {
        Cleanup(
            sourceProcessedAt: transcript.processedAt, createdAt: JSONCoding.millisecondRounded(now), method: method,
            utterances: transcript.utterances.enumerated().map { CleanedUtterance(index: $0.offset, text: clean($0.element.text)) })
    }

    static func core(_ t: String) -> String { t.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }
    static func trailingPunct(_ t: String) -> String { String(t.reversed().prefix { !($0.isLetter || $0.isNumber) }.reversed()) }
    static func endsSentence(_ t: String) -> Bool { t.last.map { ".?!".contains($0) } ?? false }

    static func removeFillers(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var capitalizeNext = false
        for (i, t) in tokens.enumerated() {
            if fillers.contains(core(t)) {
                let startsSentence = i == 0 || endsSentence(tokens[i - 1])
                let punct = trailingPunct(t)
                // "I, uh, think" -> "I think": a filler set off by commas takes the comma before it.
                if let last = out.last, last.hasSuffix(","), !punct.isEmpty { out[out.count - 1] = String(last.dropLast()) }
                // "so um." keeps the full stop on the word before.
                if let last = out.last, trailingPunct(last).isEmpty, punct.contains(where: { ".?!".contains($0) }) {
                    out[out.count - 1] = last + String(punct.filter { ".?!".contains($0) }.prefix(1))
                }
                if startsSentence, t.first?.isUppercase == true { capitalizeNext = true }
                continue
            }
            var t = t
            if capitalizeNext, let f = t.first, f.isLowercase { t = f.uppercased() + t.dropFirst() }
            capitalizeNext = false
            out.append(t)
        }
        return out
    }

    static func removeRepeats(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            // Two-word phrase repeated: "I think I think we" -> "I think we".
            if i + 3 < tokens.count, trailingPunct(tokens[i]).isEmpty, trailingPunct(tokens[i + 1]).isEmpty,
               core(tokens[i]) == core(tokens[i + 2]), core(tokens[i + 1]) == core(tokens[i + 3]), !core(tokens[i]).isEmpty {
                i += 2; continue
            }
            // One word repeated: keep the first copy's casing and the last copy's punctuation.
            if let prev = out.last, trailingPunct(prev).isEmpty, !core(prev).isEmpty, core(prev) == core(tokens[i]) {
                out[out.count - 1] = prev + trailingPunct(tokens[i])
                i += 1; continue
            }
            out.append(tokens[i]); i += 1
        }
        return out
    }
}
