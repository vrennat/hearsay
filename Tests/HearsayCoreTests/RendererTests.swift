import Foundation
import Testing
@testable import HearsayCore

@Suite struct RendererTests {
    static let header = """
    ---
    title: "Small: sync"
    started: 2026-10-02T10:00:00.000Z
    ended: 2026-10-02T10:02:05.000Z
    duration: "02:05"
    engine: parakeet
    status: done
    named: false

    """

    static let tail = """
    attendees:
      - "Tanner Vass"
      - "Priya"
    speakers:
      - id: mic-1
        name: "Tanner"
        label: "Me"
        talk_time: "00:40"
      - id: sys-1
        name: null
        label: "Remote 1"
        talk_time: "01:05"
    ---

    # Transcript


    """

    static let verbatimBody = """
    [00:01] **Tanner:** Um, hi there.

    [01:04] **Remote 1:** Hello, hello again.


    """

    @Test func rendersWithoutCleanup() {
        let (m, t) = TestSupport.smallMeeting()
        let out = TranscriptRenderer.render(meeting: m, transcript: t, cleanup: nil)
        #expect(out.markdown == Self.header + Self.tail + Self.verbatimBody)
        #expect(out.raw == out.markdown)
        #expect(!out.cleanupApplied)
    }

    @Test func appliesMatchingCleanup() {
        let (m, t) = TestSupport.smallMeeting()
        let c = Cleanup(sourceProcessedAt: t.processedAt, method: "fillers",
                        utterances: [CleanedUtterance(index: 0, text: "Hi there."), CleanedUtterance(index: 9, text: "x")])
        let out = TranscriptRenderer.render(meeting: m, transcript: t, cleanup: c)
        let cleanedBody = """
        [00:01] **Tanner:** Hi there.

        [01:04] **Remote 1:** Hello, hello again.


        """
        #expect(out.markdown == Self.header + "cleaned_by: \"fillers\"\n" + Self.tail + cleanedBody)
        #expect(out.raw == Self.header + Self.tail + Self.verbatimBody)
        #expect(out.cleanupApplied)
    }

    @Test func ignoresStaleCleanup() {
        let (m, t) = TestSupport.smallMeeting()
        let stale = Cleanup(sourceProcessedAt: t.processedAt.addingTimeInterval(-60), method: "fillers",
                            utterances: [CleanedUtterance(index: 0, text: "Hi there.")])
        let out = TranscriptRenderer.render(meeting: m, transcript: t, cleanup: stale)
        #expect(!out.cleanupApplied)
        #expect(!out.markdown.contains("cleaned_by"))
        #expect(out.markdown == Self.header + Self.tail + Self.verbatimBody)
    }

    @Test func namedIgnoresMinorVoices() throws {
        let store = try TestSupport.rootWithFixture()
        let id = TestSupport.fixtureID
        // sys-2 talks 1 s of 31 s on its stream (< 5%) and is unnamed; mic-1 and sys-1 are named.
        #expect(try TranscriptRenderer.write(store: store, id: id))
        let md = try String(contentsOf: store.folder(id).appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(md.contains("named: true"))
        #expect(md.contains("cleaned_by: \"fillers\""))
        #expect(md.contains("[00:02] **Tanner:** So the build is green."))
        #expect(md.contains("[01:01] **Remote 2:** Bye."))
        let raw = try String(contentsOf: store.folder(id).appendingPathComponent("transcript.raw.md"), encoding: .utf8)
        #expect(raw.contains("Um so, so the build is green."))
        #expect(!raw.contains("cleaned_by"))
    }
}
