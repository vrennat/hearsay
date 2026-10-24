import XCTest
@testable import HearsayCore

final class LiveLineBuilderTests: XCTestCase {
    func testTokensContinueWordsAcrossBatches() {
        var words: [Word] = []
        LiveLineBuilder.appendTokens([("\u{2581}G", 0.0, 0.1)], to: &words)
        LiveLineBuilder.appendTokens([("reat", 0.1, 0.3), (",", 0.3, 0.35), ("\u{2581}so", 0.5, 0.6), ("<blank>", 0.6, 0.7)], to: &words)
        LiveLineBuilder.appendTokens([("?", 4.0, 4.1)], to: &words)  // late punctuation does not stretch the word
        XCTAssertEqual(words, [Word(text: "Great,", start: 0, end: 0.3), Word(text: "so?", start: 0.5, end: 0.6)])
    }

    func testLinesSplitOnSpeakerAndPause() {
        let words = [
            Word(text: "hi", start: 0, end: 0.3), Word(text: "there", start: 0.4, end: 0.8),
            Word(text: "yes", start: 1.0, end: 1.3),   // slot 1 by overlap
            Word(text: "ok", start: 3.0, end: 3.2),    // pause > 0.8 s, no segment within 1 s -> slot 0
        ]
        let segs = [LiveLineBuilder.Segment(slot: 0, start: 0, end: 0.9), LiveLineBuilder.Segment(slot: 1, start: 0.95, end: 1.5)]
        let lines = LiveLineBuilder.lines(stream: .system, words: words, segments: segs)
        XCTAssertEqual(lines.map(\.speaker), ["sys-1", "sys-2", "sys-1"])
        XCTAssertEqual(lines.map(\.text), ["hi there", "yes", "ok"])
        XCTAssertEqual(lines.first?.end, 0.8)
    }
}
