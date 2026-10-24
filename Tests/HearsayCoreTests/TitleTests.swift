import XCTest
@testable import HearsayCore

private struct StubModel: TitleModel {
    var answer: String = ""
    var error: (any Error)? = nil
    var delay: Duration = .zero
    func propose(prompt: String, instructions: String) async throws -> String {
        if delay > .zero { try? await Task.sleep(for: delay) }
        if let error { throw error }
        return answer
    }
}

/// A `TitleModel` that records the prompt it was given.
private final class RecordingModel: TitleModel, @unchecked Sendable {
    var prompts: [String] = []
    func propose(prompt: String, instructions: String) async throws -> String {
        prompts.append(prompt)
        return "Release Readiness Review"
    }
}

final class TitleRulesTests: XCTestCase {
    func testGenericTitles() {
        let names = ["Tanner Vass", "Rob Example"]
        for t in ["", "Meeting", "Untitled", "Sync", "sync", "1:1", "Weekly 1:1", "Catch up", "Call", "Quick call",
                  "Meeting Oct 23 09:30", "2026-10-23 09:30 Meeting", "Rob / Tanner", "Rob <> Tanner",
                  "Catch up with Rob", "Tanner and Rob sync", "Team Standup"] {
            XCTAssertTrue(TitleRules.isGeneric(t, names: names), t)
        }
        for t in ["Q4 Planning Review", "Fixture standup", "Small: sync", "Hearsay launch plan", "Rob / Tanner: pricing"] {
            XCTAssertFalse(TitleRules.isGeneric(t, names: names), t)
        }
    }

    func testNeedsGenerationRespectsUserEdits() {
        var m = Meeting(id: "x", title: "Sync", startedAt: Date())
        XCTAssertTrue(TitleRules.needsGeneration(m))
        m.titleEditedByUser = true
        XCTAssertFalse(TitleRules.needsGeneration(m))
        m.titleEditedByUser = false
        m.title = "Q4 Planning Review"
        XCTAssertFalse(TitleRules.needsGeneration(m))
    }

    func testValidationAcceptsGoodTitles() {
        for t in ["Release Readiness Review", "Q4 Pricing and Packaging Decisions", "Plan for the Hearsay Beta",
                  "  Echo Filter   Tuning Results ", "Onboarding Flow (Draft) Review"] {
            guard case .success = TitleRules.validate(t) else { return XCTFail(t) }
        }
        XCTAssertEqual(try TitleRules.validate("  Echo Filter   Tuning Results ").get(), "Echo Filter Tuning Results")
    }

    func testValidationRejections() {
        let names = ["Priya Example", "Tanner Vass"]
        let cases: [(String, TitleRules.Rejection)] = [
            ("Pricing", .wordCount(1)),
            ("One Two Three Four Five Six Seven Eight Nine", .wordCount(9)),
            ("Release readiness review", .notTitleCase("readiness")),
            ("\"Release Readiness Review\"", .quotes),
            ("'Release Readiness Review'", .quotes),
            ("Release Readiness Review.", .trailingPunctuation),
            ("Release Readiness Review!", .trailingPunctuation),
            ("October Release Readiness Review", .date),
            ("Release Review 2026 Kickoff", .date),
            ("Release Review on 10/23", .date),
            ("Monday Release Readiness Check", .date),
            ("Release Readiness Team Meeting", .meetingFiller),
            ("Priya and Tanner", .nameOnly),
            ("Priya Example Tanner", .nameOnly),
            ("Weekly Team Sync", .generic),
            ("Priya Tanner Catch Up", .generic),
        ]
        for (title, want) in cases {
            XCTAssertEqual(TitleRules.validate(title, names: names), .failure(want), title)
        }
    }

    func testPromptUsesCleanupNamesAndCapsWords() throws {
        let store = try TestSupport.rootWithFixture()
        let id = TestSupport.fixtureID
        var meeting = try store.loadMeeting(id)
        let transcript = try XCTUnwrap(try store.loadTranscript(id))
        let cleanup = try store.loadCleanup(id)
        let p = TitleRules.prompt(meeting: meeting, transcript: transcript, cleanup: cleanup,
                                  timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        XCTAssertEqual(p, """
            Calendar title: Fixture standup
            Attendees: Tanner Vass, Priya Example
            Date: Thursday 1 October 2026, 09:30
            Duration: 1 min
            Speakers: Priya, Tanner, Remote 2

            Transcript (start):
            Tanner: So the build is green.
            Priya: Great, ship it today.
            Remote 2: Bye.
            """)
        // A recorder placeholder is not a calendar title.
        meeting.title = "Meeting Oct 1 09:30"
        XCTAssertFalse(TitleRules.prompt(meeting: meeting, transcript: transcript, cleanup: nil).contains("Calendar title"))

        let long = Transcript(engine: "parakeet", processedAt: Date(), speakers: [], utterances: (0..<40).map {
            Utterance(speaker: "mic-1", stream: .mic, start: Double($0), end: Double($0) + 1,
                      text: Array(repeating: "word", count: 50).joined(separator: " "))
        })
        let body = TitleRules.prompt(meeting: meeting, transcript: long, cleanup: nil).components(separatedBy: "Transcript (start):\n")[1]
        XCTAssertEqual(body.split(whereSeparator: { $0 == " " || $0 == "\n" }).filter { $0 == "word" }.count, TitleRules.excerptWords)
    }
}

final class TitleGeneratorTests: XCTestCase {
    private func meeting(_ title: String, edited: Bool = false) -> (Meeting, Transcript) {
        var (m, t) = TestSupport.smallMeeting()
        m.title = title
        m.titleEditedByUser = edited
        return (m, t)
    }

    func testGeneratesForGenericTitle() async {
        let (m, t) = meeting("Sync")
        let o = await TitleGenerator.title(meeting: m, transcript: t, cleanup: nil, model: StubModel(answer: "Release Readiness Review"))
        XCTAssertEqual(o, .init(title: "Release Readiness Review", source: .generated, reason: nil))
    }

    func testKeepsSpecificAndUserTitlesWithoutAskingTheModel() async {
        let model = RecordingModel()
        var (m, t) = meeting("Q4 Planning Review")
        var o = await TitleGenerator.title(meeting: m, transcript: t, cleanup: nil, model: model)
        XCTAssertEqual(o.source, .kept)
        XCTAssertEqual(o.title, "Q4 Planning Review")
        (m, t) = meeting("Sync", edited: true)
        o = await TitleGenerator.title(meeting: m, transcript: t, cleanup: nil, model: model)
        XCTAssertEqual(o, .init(title: "Sync", source: .userEdited, reason: nil))
        XCTAssertTrue(model.prompts.isEmpty)
    }

    func testFallbacks() async {
        let (m, t) = meeting("")
        let dateTitle = Titler.dateTimeTitle(m.startedAt)
        var o = await TitleGenerator.title(meeting: m, transcript: t, cleanup: nil, model: StubModel(answer: "Tanner and Priya"))
        XCTAssertEqual(o.title, dateTitle)
        XCTAssertEqual(o.source, .fallback)
        XCTAssertEqual(o.reason, "rejected \"Tanner and Priya\": only a person's name")

        o = await TitleGenerator.title(meeting: m, transcript: t, cleanup: nil,
                                       model: StubModel(error: TitleModelError.unavailable("Apple Intelligence is turned off in System Settings.")))
        XCTAssertEqual(o.title, dateTitle)
        XCTAssertEqual(o.reason, "model unavailable: Apple Intelligence is turned off in System Settings.")

        o = await TitleGenerator.title(meeting: m, transcript: t, cleanup: nil, model: StubModel(error: CocoaError(.featureUnsupported)))
        XCTAssertEqual(o.source, .fallback)

        let started = ContinuousClock.now
        o = await TitleGenerator.title(meeting: m, transcript: t, cleanup: nil,
                                       model: StubModel(answer: "Release Readiness Review", delay: .seconds(5)), timeout: .milliseconds(200))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        XCTAssertEqual(o.title, dateTitle)
        XCTAssertEqual(o.reason, "no answer within 0.2 seconds")
    }

    func testDecodesMissingFlagAndUserEditSetsIt() throws {
        let store = try TestSupport.rootWithFixture()
        XCTAssertFalse(try store.loadMeeting(TestSupport.fixtureID).titleEditedByUser)
        try MeetingEdits.setTitle(id: TestSupport.fixtureID, title: "Build Status Check", store: store)
        XCTAssertTrue(try store.loadMeeting(TestSupport.fixtureID).titleEditedByUser)
        let raw = try String(contentsOf: store.folder(TestSupport.fixtureID).appendingPathComponent("meeting.json"), encoding: .utf8)
        XCTAssertTrue(raw.contains("\"titleEditedByUser\" : true") || raw.contains("\"titleEditedByUser\":true"))
        XCTAssertTrue(try String(contentsOf: store.folder(TestSupport.fixtureID).appendingPathComponent("transcript.md"), encoding: .utf8)
            .contains("Build Status Check"))
    }

    /// The real FoundationModels call. Skips when Apple Intelligence is unavailable on this Mac.
    func testOnDeviceModelProposesAValidTitle() async throws {
        if let reason = SpeakerSummaries.unavailableReason() { throw XCTSkip("FoundationModels unavailable: \(reason)") }
        let store = try TestSupport.rootWithFixture()
        var m = try store.loadMeeting(TestSupport.fixtureID)
        m.title = "Sync"
        let t = try XCTUnwrap(try store.loadTranscript(TestSupport.fixtureID))
        let o = await TitleGenerator.suggest(meeting: m, transcript: t, cleanup: try store.loadCleanup(TestSupport.fixtureID))
        // A tiny transcript may still be rejected by validation; either way the outcome is well formed.
        switch o.source {
        case .generated: XCTAssertNoThrow(try TitleRules.validate(o.title, names: TitleRules.knownNames(m)).get())
        case .fallback: XCTAssertNotNil(o.reason); XCTAssertFalse(o.reason!.hasPrefix("model unavailable"))
        default: XCTFail("unexpected \(o.source)")
        }
        print("on-device title: \(o.title) [\(o.source.rawValue)] \(o.reason ?? "")")
    }
}
