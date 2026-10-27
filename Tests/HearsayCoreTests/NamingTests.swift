import XCTest
@testable import HearsayCore

final class NamingTests: XCTestCase {
    /// Unit vector mostly along axis `i`, tilted toward axis `j` so its cosine with `axis(i)` is `c`.
    static func vec(_ i: Int, cos c: Float, toward j: Int = 100) -> [Float] {
        var v = [Float](repeating: 0, count: 192)
        v[i] = c; v[j] = (1 - c * c).squareRoot()
        return v
    }
    static func axis(_ i: Int) -> [Float] { vec(i, cos: 1) }

    func s(_ id: String, _ talk: Double, voice: [Float]? = nil) -> Speaker {
        Speaker(id: id, stream: id.hasPrefix("sys") ? .system : .mic, defaultLabel: id, talkSeconds: talk, voice: voice)
    }

    // MARK: Voiceprint thresholds

    func testVoiceprintThresholdAndMargin() {
        let me = [Self.axis(0)]
        // 0.70 vs 0.54: you.
        XCTAssertEqual(Voiceprint.match(speakers: [s("mic-1", 10, voice: Self.vec(0, cos: 0.54)), s("mic-2", 10, voice: Self.vec(0, cos: 0.70, toward: 101))], samples: me), "mic-2")
        // Under 0.6: nobody.
        XCTAssertNil(Voiceprint.match(speakers: [s("mic-1", 10, voice: Self.vec(0, cos: 0.59))], samples: me))
        // 0.6 alone is enough.
        XCTAssertEqual(Voiceprint.match(speakers: [s("mic-1", 10, voice: Self.vec(0, cos: 0.6))], samples: me), "mic-1")
        // 0.80 vs 0.66: only 0.14 ahead, nobody.
        XCTAssertNil(Voiceprint.match(speakers: [s("mic-1", 10, voice: Self.vec(0, cos: 0.80)), s("mic-2", 10, voice: Self.vec(0, cos: 0.66, toward: 101))], samples: me))
        // System voices do not count against the margin.
        XCTAssertEqual(Voiceprint.match(speakers: [s("mic-1", 10, voice: Self.vec(0, cos: 0.8)), s("sys-1", 10, voice: Self.axis(0))], samples: me), "mic-1")
        // Best sample wins: the second sample matches.
        XCTAssertEqual(Voiceprint.match(speakers: [s("mic-1", 10, voice: Self.axis(5))], samples: [Self.axis(0), Self.vec(5, cos: 0.9)]), "mic-1")
        XCTAssertNil(Voiceprint.match(speakers: [s("mic-1", 10, voice: Self.axis(0))], samples: []))
    }

    func testVoiceprintSamplesOnePerMeetingByFirstName() throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        func add(_ id: String, _ names: [String: String], _ speakers: [Speaker]) throws {
            try FileManager.default.createDirectory(at: store.folder(id), withIntermediateDirectories: true)
            try store.saveMeeting(Meeting(id: id, title: id, startedAt: Date(), status: .done, speakerNames: names))
            try store.saveTranscript(Transcript(engine: "parakeet", processedAt: Date(), speakers: speakers, utterances: []), id: id)
        }
        try add("a", ["mic-1": "Tanner Vass", "mic-2": "Tanner"], [s("mic-1", 5, voice: Self.axis(1)), s("mic-2", 50, voice: Self.axis(2))])
        try add("b", ["sys-1": "Tanner"], [s("sys-1", 50, voice: Self.axis(3))])
        try add("c", ["mic-1": "Priya"], [s("mic-1", 50, voice: Self.axis(4))])
        try add("self", ["mic-1": "Tanner"], [s("mic-1", 50, voice: Self.axis(5))])
        XCTAssertEqual(Voiceprint.samples(store: store, firstName: "tanner", excluding: "self"), [Self.axis(2)])
    }

    // MARK: Known voices (people named before)

    func k(_ name: String, _ stream: StreamKind, _ v: [Float]) -> KnownVoices.Sample { .init(name: name, stream: stream, voice: v) }

    func testKnownVoicesNameGroupCallSpeakers() {
        let speakers = [s("mic-1", 300, voice: Self.axis(0)), s("sys-1", 200, voice: Self.vec(1, cos: 0.8)),
                        s("sys-2", 200, voice: Self.vec(2, cos: 0.7)), s("sys-3", 100, voice: Self.axis(9))]
        let known = twice([k("Priya", .system, Self.axis(1)), k("Omar Webb", .system, Self.axis(2)), k("Tanner", .mic, Self.axis(0))])
        let out = Naming.name(.init(speakers: speakers, me: "Tanner", attendees: [], voiceprintSamples: [Self.axis(0)], knownVoices: known))
        XCTAssertEqual(out.names, ["mic-1": "Tanner", "sys-1": "Priya", "sys-2": "Omar Webb"])
        XCTAssertEqual(out.inferred, ["mic-1", "sys-1", "sys-2"])
        // One sample is not enough.
        let once = Naming.name(.init(speakers: speakers, me: nil, knownVoices: [k("Priya", .system, Self.axis(1))]))
        XCTAssertEqual(once.names, [:])
    }

    /// Each sample as if seen in two meetings.
    func twice(_ xs: [KnownVoices.Sample]) -> [KnownVoices.Sample] { xs + xs }

    func testKnownVoiceAmbiguityCountsVoicesThatFailTheirOwnGates() {
        // sys-2 is nearly as close to Priya but is itself too close to Bob to qualify: still blocks sys-1.
        let known = twice([k("Priya", .system, Self.axis(1)), k("Bob", .system, Self.axis(3))])
        let a = Self.vec(1, cos: 0.70, toward: 50)
        var b = [Float](repeating: 0, count: 192); b[1] = 0.69; b[3] = 0.60; b[60] = (1 - 0.69 * 0.69 - 0.36).squareRoot()
        XCTAssertEqual(KnownVoices.match(speakers: [s("sys-1", 9, voice: a), s("sys-2", 9, voice: b)], samples: known, taken: []), [:])
    }

    func testKnownVoiceNotGivenWhenFirstNameTaken() {
        let out = Naming.name(.init(speakers: [s("sys-1", 9, voice: Self.axis(1)), s("sys-2", 9, voice: Self.axis(2))],
                                    existing: ["sys-1": "Jordan Kim"], me: nil, knownVoices: twice([k("Jordan", .system, Self.axis(2))])))
        XCTAssertEqual(out.names, ["sys-1": "Jordan Kim"])
    }

    func testKnownVoicesThresholdMarginAndStream() {
        let known = twice([k("Priya", .system, Self.axis(1)), k("Jordan", .system, Self.vec(1, cos: 0.9, toward: 3))])
        // Below 0.65: no name.
        XCTAssertEqual(KnownVoices.match(speakers: [s("sys-1", 9, voice: Self.vec(5, cos: 1))], samples: twice([k("Priya", .system, Self.vec(5, cos: 0.64))]), taken: []), [:])
        // Two known names too close together: no name.
        XCTAssertEqual(KnownVoices.match(speakers: [s("sys-1", 9, voice: Self.axis(1))], samples: known, taken: []), [:])
        // A room sample never names a call voice.
        XCTAssertEqual(KnownVoices.match(speakers: [s("sys-1", 9, voice: Self.axis(1))], samples: twice([k("Priya", .mic, Self.axis(1))]), taken: []), [:])
        // A name already used in the meeting is not handed out again.
        XCTAssertEqual(KnownVoices.match(speakers: [s("sys-1", 9, voice: Self.axis(1))], samples: twice([k("Priya", .system, Self.axis(1))]), taken: ["priya"]), [:])
        // Two voices in this meeting both close to Priya: neither gets it.
        XCTAssertEqual(KnownVoices.match(speakers: [s("sys-1", 9, voice: Self.axis(1)), s("sys-2", 9, voice: Self.vec(1, cos: 0.9))],
                                         samples: twice([k("Priya", .system, Self.axis(1))]), taken: []), [:])
    }

    func testKnownVoicesNeverOverrideTypedOrLiveNames() {
        let out = Naming.name(.init(speakers: [s("sys-1", 9, voice: Self.axis(1))], existing: ["sys-1": "Sam"], me: nil,
                                    knownVoices: twice([k("Priya", .system, Self.axis(1))])))
        XCTAssertEqual(out.names, ["sys-1": "Sam"])
        let live = Naming.name(.init(speakers: [s("sys-1", 9, voice: Self.axis(1))], live: ["sys-1": "Jo"], me: nil,
                                     knownVoices: twice([k("Priya", .system, Self.axis(1))])))
        XCTAssertEqual(live.names, ["sys-1": "Jo"])
        XCTAssertEqual(live.inferred, [])
    }

    func testKnownVoiceSamplesSkipThisMeetingAndUnnamed() throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        func add(_ id: String, _ names: [String: String], _ speakers: [Speaker]) throws {
            try FileManager.default.createDirectory(at: store.folder(id), withIntermediateDirectories: true)
            try store.saveMeeting(Meeting(id: id, title: id, startedAt: Date(), status: .done, speakerNames: names))
            try store.saveTranscript(Transcript(engine: "parakeet", processedAt: Date(), speakers: speakers, utterances: []), id: id)
        }
        try add("a", ["sys-1": "Priya", "sys-2": " "], [s("sys-1", 5, voice: Self.axis(1)), s("sys-2", 5, voice: Self.axis(2)), s("sys-3", 5, voice: Self.axis(3))])
        try add("self", ["sys-1": "Omar"], [s("sys-1", 5, voice: Self.axis(4))])
        // A guessed name is never a sample.
        try add("guess", ["sys-1": "Sam"], [s("sys-1", 5, voice: Self.axis(6))])
        var g = try store.loadMeeting("guess"); g.inferredSpeakers = ["sys-1"]; try store.saveMeeting(g)
        XCTAssertEqual(KnownVoices.samples(store: store, excluding: "self"),
                       [KnownVoices.Sample(name: "Priya", stream: .system, voice: Self.axis(1), meetingID: "a")])
        // Renaming by hand makes it a typed name again.
        _ = try MeetingEdits.rename(id: "guess", speaker: "sys-1", name: "Sam", store: store)
        XCTAssertEqual(try store.loadMeeting("guess").inferredSpeakers, [])
    }

    // MARK: Priority and 1:1 rules

    func testPriorityExistingThenLiveThenInvite() {
        let out = Naming.name(.init(
            speakers: [s("mic-1", 60), s("sys-1", 60)],
            existing: ["mic-1": "Pat"], live: ["mic-1": "Live Name", "sys-1": "Pat"],
            me: "Tanner", attendees: ["Tanner", "Priya"]))
        // mic-1 keeps Pat; live "Pat" is already used so sys-1 falls to the invite.
        XCTAssertEqual(out.names, ["mic-1": "Pat", "sys-1": "Priya"])
    }

    func testOneOnOneCallNamesBoth() {
        let out = Naming.name(.init(speakers: [s("mic-1", 300), s("sys-1", 280)], me: "Tanner Vass",
                                    attendees: ["Tanner Vass", "Priya Ortiz"]))
        XCTAssertEqual(out.names, ["mic-1": "Tanner", "sys-1": "Priya"])
        XCTAssertEqual(out.me, "mic-1")
    }

    func testOneOnOneCountsAgainstYourNameWhenMeMissingFromInvite() {
        // The invite lists only the other person; `me` comes from the setting.
        let out = Naming.name(.init(speakers: [s("mic-1", 300), s("sys-1", 280)], me: "Tanner", attendees: ["Priya"]))
        XCTAssertEqual(out.names, ["mic-1": "Tanner", "sys-1": "Priya"])
    }

    func testInRoomOneOnOneNeedsVoiceprint() {
        let speakers = [s("mic-1", 300, voice: Self.axis(9)), s("mic-2", 200, voice: Self.axis(0))]
        let none = Naming.name(.init(speakers: speakers, me: "Tanner", attendees: ["Tanner", "Priya"]))
        XCTAssertEqual(none.names, [:])
        let vp = Naming.name(.init(speakers: speakers, me: "Tanner", attendees: ["Tanner", "Priya"], voiceprintSamples: [Self.axis(0)]))
        XCTAssertEqual(vp.names, ["mic-2": "Tanner", "mic-1": "Priya"])
        XCTAssertEqual(vp.me, "mic-2")
    }

    func testMinorVoicesUnderFivePercentDoNotCount() {
        // sys-2 has 4% of the system stream: still exactly one other main voice.
        let out = Naming.name(.init(speakers: [s("mic-1", 300), s("sys-1", 96), s("sys-2", 4)], me: "Tanner", attendees: ["Tanner", "Priya"]))
        XCTAssertEqual(out.names, ["mic-1": "Tanner", "sys-1": "Priya"])
        // At 5% it counts, so the other name is ambiguous.
        let two = Naming.name(.init(speakers: [s("mic-1", 300), s("sys-1", 95), s("sys-2", 5)], me: "Tanner", attendees: ["Tanner", "Priya"]))
        XCTAssertEqual(two.names, ["mic-1": "Tanner"])
    }

    func testGroupInviteDoesNotName() {
        let out = Naming.name(.init(speakers: [s("mic-1", 300), s("sys-1", 280)], me: "Tanner", attendees: ["Tanner", "Priya", "Nate"]))
        XCTAssertEqual(out.names, [:])
        XCTAssertNil(out.me)
    }

    func testNoNameSkipsInviteAndVoiceprint() {
        let out = Naming.name(.init(speakers: [s("mic-1", 300, voice: Self.axis(0))], me: nil, attendees: ["Tanner", "Priya"], voiceprintSamples: [Self.axis(0)]))
        XCTAssertEqual(out.names, [:])
    }

    func testNicknameFromTitle() {
        XCTAssertEqual(Naming.displayName("Robert Hart", title: "Rob / Tanner"), "Rob")
        XCTAssertEqual(Naming.displayName("Robert Hart", title: "Ro / Tanner"), "Robert")
        XCTAssertEqual(Naming.displayName("robert.hart@example.com", title: ""), "Robert")
        let out = Naming.name(.init(speakers: [s("mic-1", 300), s("sys-1", 280)], me: "Tanner", attendees: ["Tanner Vass", "Robert Hart"], title: "Rob / Tanner"))
        XCTAssertEqual(out.names["sys-1"], "Rob")
    }

    // MARK: Live names

    func testLiveNamesMapByCoverage() {
        let live = LiveTranscript(updatedAt: Date(), speakerNames: ["mic-1": "Nate", "mic-2": "Priya", "sys-1": "Unmatched"], lines: [
            LiveLine(speaker: "mic-1", stream: .mic, start: 0, end: 10, text: ""),
            LiveLine(speaker: "mic-2", stream: .mic, start: 10, end: 20, text: ""),
            LiveLine(speaker: "sys-1", stream: .system, start: 0, end: 10, text: ""),
        ])
        let utts = [
            Utterance(speaker: "mic-2", stream: .mic, start: 0, end: 9, text: ""),     // covers 90% of Nate
            Utterance(speaker: "mic-1", stream: .mic, start: 10, end: 14, text: ""),   // 40% of Priya: not enough
            Utterance(speaker: "sys-1", stream: .system, start: 0, end: 4, text: ""),  // 40%
        ]
        let t = Transcript(engine: "parakeet", processedAt: Date(), speakers: [
            Speaker(id: "mic-1", stream: .mic, defaultLabel: "Room 1", talkSeconds: 4),
            Speaker(id: "mic-2", stream: .mic, defaultLabel: "Room 2", talkSeconds: 9),
            Speaker(id: "sys-1", stream: .system, defaultLabel: "Remote 1", talkSeconds: 4),
        ], utterances: utts)
        XCTAssertEqual(LiveNameMapper.map(live: live, transcript: t), ["mic-2": "Nate"])
    }
}
