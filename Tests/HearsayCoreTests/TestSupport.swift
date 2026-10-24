import Foundation
@testable import HearsayCore

enum TestSupport {
    static let fixtureID = "2026-10-01 0930 Fixture standup"

    static func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hearsay-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A temp root holding a copy of the synthetic fixture meeting folder.
    static func rootWithFixture(_ ids: [String] = [fixtureID]) throws -> MeetingStore {
        let root = try tempRoot()
        guard let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        for id in ids { try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent(id), to: root.appendingPathComponent(id)) }
        return MeetingStore(root: root)
    }

    static func date(_ s: String) -> Date {
        JSONCoding.parseDate(s) ?? Date(timeIntervalSince1970: 0)
    }

    /// Two speakers, one named; processedAt 2026-10-02T10:00:00.500Z.
    static func smallMeeting() -> (Meeting, Transcript) {
        let start = date("2026-10-02T10:00:00.000Z")
        let meeting = Meeting(
            id: "2026-10-02 1000 Small", title: "Small: sync", startedAt: start,
            endedAt: start.addingTimeInterval(125), status: .done, engine: "parakeet",
            speakerNames: ["mic-1": "Tanner"], attendees: ["Tanner Vass", "Priya"])
        let transcript = Transcript(
            engine: "parakeet", processedAt: date("2026-10-02T10:00:00.500Z"),
            speakers: [
                Speaker(id: "mic-1", stream: .mic, defaultLabel: "Me", talkSeconds: 40),
                Speaker(id: "sys-1", stream: .system, defaultLabel: "Remote 1", talkSeconds: 65),
            ],
            utterances: [
                Utterance(speaker: "mic-1", stream: .mic, start: 1.2, end: 5, text: "Um, hi there."),
                Utterance(speaker: "sys-1", stream: .system, start: 64, end: 70, text: "Hello, hello again."),
            ])
        return (meeting, transcript)
    }
}
