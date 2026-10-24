import Foundation

/// Spelling fixes from `glossary.txt` lines of the form `wrong => Right`; `#` starts a comment.
public struct Glossary: Sendable, Equatable {
    public static let fileName = "glossary.txt"

    public struct Entry: Sendable, Equatable {
        public let wrong: String
        public let right: String
    }

    public let entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    public init(text: String) {
        entries = text.split(whereSeparator: \.isNewline).compactMap { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, !s.hasPrefix("#") else { return nil }
            let parts = s.components(separatedBy: "=>")
            guard parts.count == 2 else { return nil }
            let wrong = parts[0].trimmingCharacters(in: .whitespaces)
            let right = parts[1].trimmingCharacters(in: .whitespaces)
            guard !wrong.isEmpty, !right.isEmpty else { return nil }
            return Entry(wrong: wrong, right: right)
        }
    }

    public static func load(root: URL) -> Glossary {
        let url = root.appendingPathComponent(fileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return Glossary(entries: []) }
        return Glossary(text: text)
    }

    /// Whole-word, case-insensitive replacement. An all-caps or capitalised match keeps that casing
    /// unless the replacement has its own capitals.
    public func apply(_ text: String) -> String {
        var out = text
        for e in entries {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: e.wrong) + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                result += Self.cased(e.right, like: ns.substring(with: m.range))
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out
    }

    static func cased(_ replacement: String, like match: String) -> String {
        if replacement != replacement.lowercased() { return replacement }
        if match == match.uppercased(), match != match.lowercased(), match.count > 1 { return replacement.uppercased() }
        if let f = match.first, f.isUppercase { return replacement.prefix(1).uppercased() + replacement.dropFirst() }
        return replacement
    }

    public func apply(to transcript: Transcript) -> Transcript {
        guard !entries.isEmpty else { return transcript }
        var t = transcript
        t.utterances = t.utterances.map { u in
            var u = u
            u.text = apply(u.text)
            return u
        }
        return t
    }
}
