import XCTest
@testable import HearsayCore

final class NameHintsTests: XCTestCase {
    let names: Set<String> = ["Nate", "Priya", "Omar"]

    func u(_ speaker: String, _ start: Double, _ end: Double, _ text: String) -> Utterance {
        Utterance(speaker: speaker, stream: speaker.hasPrefix("sys") ? .system : .mic, start: start, end: end, text: text)
    }

    func hint(_ us: [Utterance]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: NameHints.hints(utterances: us, candidates: names).map { ($0.speaker, $0.name) })
    }

    func testGreetingPointsAtNextVoice() {
        let h = NameHints.hints(utterances: [u("mic-1", 0, 2, "Hey Nate, how's it going?"), u("sys-1", 3, 5, "Good, you?")], candidates: names)
        XCTAssertEqual(h.map(\.speaker), ["sys-1"])
        XCTAssertEqual(h.first?.name, "Nate")
        XCTAssertEqual(h.first?.quote, "Hey Nate, how's it going?")
    }

    func testVocativeEndingQuestion() {
        XCTAssertEqual(hint([u("mic-1", 0, 2, "Okay. So what's next up, Priya?"), u("sys-2", 2.5, 5, "The launch.")]), ["sys-2": "Priya"])
    }

    func testThanksPointsAtVoiceBefore() {
        XCTAssertEqual(hint([u("sys-1", 0, 4, "That's the update."), u("mic-1", 5, 6, "Thanks, Omar.")]), ["sys-1": "Omar"])
    }

    func testRetoldSpeechExcluded() {
        XCTAssertEqual(hint([u("mic-1", 0, 2, "Well he said Nate was late."), u("sys-1", 3, 5, "Yes.")]), [:])
        XCTAssertEqual(hint([u("mic-1", 0, 2, "She told me, Nate?"), u("sys-1", 3, 5, "Yes.")]), [:])
    }

    func testMidSentenceMentionIsNoCue() {
        XCTAssertEqual(hint([u("mic-1", 0, 2, "I think Nate has the numbers."), u("sys-1", 3, 5, "Yes.")]), [:])
        // Comma-set-off but not ending a question or the turn.
        XCTAssertEqual(hint([u("mic-1", 0, 2, "Right, Nate. Then we ship."), u("sys-1", 3, 5, "Yes.")]), [:])
    }

    func testVocativeEndingTheTurn() {
        XCTAssertEqual(hint([u("mic-1", 0, 2, "Go ahead, Nate."), u("sys-1", 3, 5, "Sure.")]), ["sys-1": "Nate"])
    }

    func testNextVoiceMustBeWithinFourSeconds() {
        XCTAssertEqual(hint([u("mic-1", 0, 2, "Hey Nate."), u("sys-1", 6.5, 8, "Hi.")]), [:])
    }

    func testNextVoiceAmongNextThreeTurns() {
        // Same-speaker utterances merge into one turn, so the next other voice is found.
        XCTAssertEqual(hint([u("mic-1", 0, 2, "Hi Priya."), u("mic-1", 2.2, 3, "Can you hear me?"), u("sys-1", 4, 5, "Yes.")]), ["sys-1": "Priya"])
    }

    func testUncapitalizedOrUnknownNamesIgnored() {
        XCTAssertEqual(hint([u("mic-1", 0, 2, "Hey nate."), u("sys-1", 3, 5, "Hi.")]), [:])
        XCTAssertEqual(hint([u("mic-1", 0, 2, "Hey Bob."), u("sys-1", 3, 5, "Hi.")]), [:])
    }

    func testMostVotesThenFirstHeard() {
        let us = [
            u("mic-1", 0, 1, "Hey Nate."), u("sys-1", 1.5, 3, "Hi."),
            u("mic-1", 4, 5, "Hi Priya."), u("sys-1", 5.5, 7, "Hello."),
            u("mic-1", 8, 9, "Morning Priya."), u("sys-1", 9.5, 11, "Hey."),
        ]
        XCTAssertEqual(hint(us), ["sys-1": "Priya"])
        XCTAssertEqual(hint(Array(us.prefix(4))), ["sys-1": "Nate"])  // tie: first heard
    }

    func testCandidatesAreCapitalizedFirstNames() {
        XCTAssertEqual(NameHints.candidates(attendees: ["Tanner Vass", "priya@x.com"], typedNames: ["Nate", "robert smith"]),
                       ["Tanner", "Nate", "Robert"])
    }
}

final class DictationCleanupTests: XCTestCase {
    func testStripsFillersAndRepeats() {
        XCTAssertEqual(TextCleaner.clean("Um, so I, uh, think the the plan works."), "So I think the plan works.")
        XCTAssertEqual(TextCleaner.clean("It works um."), "It works.")
        XCTAssertEqual(TextCleaner.clean("Plain text stays."), "Plain text stays.")
        XCTAssertEqual(TextCleaner.clean("Done. Done."), "Done. Done.")
    }
}
