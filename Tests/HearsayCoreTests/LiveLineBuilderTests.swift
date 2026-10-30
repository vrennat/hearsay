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
            Word(text: "ok", start: 3.0, end: 3.2),    // no segment: must not impersonate slot 0
        ]
        let segs = [LiveLineBuilder.Segment(slot: 0, start: 0, end: 0.9), LiveLineBuilder.Segment(slot: 1, start: 0.95, end: 1.5)]
        let lines = LiveLineBuilder.lines(stream: .system, words: words, segments: segs)
        XCTAssertEqual(lines.map(\.speaker), ["sys-1", "sys-2", "sys-unknown"])
        XCTAssertEqual(lines.map(\.text), ["hi there", "yes", "ok"])
        XCTAssertEqual(lines.first?.end, 0.8)
    }

    func testUnmatchedAndAmbiguousWordsNeverBorrowANearbyVoice() {
        let word = Word(text: "synthetic", start: 2, end: 2.5)
        XCTAssertNil(LiveLineBuilder.slot(for: word, in: []))
        XCTAssertNil(LiveLineBuilder.slot(for: word, in: [.init(slot: 0, start: 1, end: 1.9)]))
        XCTAssertNil(LiveLineBuilder.slot(for: word, in: [.init(slot: 0, start: 2, end: 3), .init(slot: 1, start: 2, end: 3)]))
    }

    func testDelayedSegmentsRecoverFourVoicesWithoutChangingWords() {
        let words = (0..<4).map { Word(text: "synthetic", start: Double($0 * 2), end: Double($0 * 2) + 0.5) }
        let segments = (0..<4).map { LiveLineBuilder.Segment(slot: $0, start: Double($0 * 2), end: Double($0 * 2) + 1) }
        let pending = LiveLineBuilder.lines(stream: .system, words: words, segments: [])
        XCTAssertTrue(pending.allSatisfy { $0.speaker == "sys-unknown" })
        let resolved = LiveLineBuilder.lines(stream: .system, words: words, segments: segments)
        XCTAssertEqual(resolved.map(\.speaker), ["sys-1", "sys-2", "sys-3", "sys-4"])
        XCTAssertEqual(resolved.map(\.text), pending.map(\.text))
        XCTAssertEqual(LiveLineBuilder.diagnostics(words: words, segments: segments), "words=4 matched=4 uncertain=0 segmentSlots=4 matchedSlots=4 segments=4")
        XCTAssertEqual(LiveLineBuilder.diagnostics(words: words, segments: []), "words=4 matched=0 uncertain=4 segmentSlots=0 matchedSlots=0 segments=0")
    }
}
