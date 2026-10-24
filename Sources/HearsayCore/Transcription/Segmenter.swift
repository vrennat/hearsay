import Foundation

/// Splits a word stream into utterances at pauses and after sentence-ending words.
public enum Segmenter {
    public static func utterances(
        words: [Word], speaker: String, stream: StreamKind,
        pause: Double = 0.8, maxLength: Double = 30
    ) -> [Utterance] {
        var out: [Utterance] = []
        var current: [Word] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
            out.append(Utterance(speaker: speaker, stream: stream, start: first.start, end: last.end, text: text, words: current))
            current = []
        }

        for w in words {
            if let prev = current.last, let first = current.first {
                let gap = w.start - prev.end
                let sentenceEnd = prev.text.last.map { ".?!".contains($0) } ?? false
                if gap >= pause || (sentenceEnd && gap >= 0.3) || w.end - first.start > maxLength { flush() }
            }
            current.append(w)
        }
        flush()
        return out
    }
}
