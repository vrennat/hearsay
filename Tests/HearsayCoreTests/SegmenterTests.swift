import Testing
@testable import HearsayCore

@Suite struct SegmenterTests {
    @Test func splitsAtPausesAndSentenceEnds() {
        let words = [
            Word(text: "Hello", start: 0, end: 0.4), Word(text: "there.", start: 0.5, end: 0.9),
            Word(text: "New", start: 1.3, end: 1.5), Word(text: "point", start: 1.6, end: 1.9),
            Word(text: "later", start: 3.0, end: 3.4),
        ]
        let u = Segmenter.utterances(words: words, speaker: "mic-1", stream: .mic)
        #expect(u.map(\.text) == ["Hello there.", "New point", "later"])
        #expect(u[1].start == 1.3 && u[1].end == 1.9)
    }
}
