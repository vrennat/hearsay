import Foundation

/// `live.md` from `live.json`.
public enum LiveRenderer {
    public static func markdown(_ live: LiveTranscript) -> String {
        var out = "# Live transcript\n\nUpdated \(Format.date(live.updatedAt))\n\n"
        for l in live.lines {
            let text = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            out += "[\(Format.clock(l.start))] **\(live.speakerNames[l.speaker] ?? l.speaker):** \(text)\n\n"
        }
        return out
    }
}
