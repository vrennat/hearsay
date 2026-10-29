import Testing
@testable import HearsayCore

@Suite struct GlossaryTests {
    let g = Glossary(text: """
    # comment => ignored
    hear say => Hearsay
    fluid audio => FluidAudio
    reece => priya
    bad line
    """)

    @Test func parses() { #expect(g.entries.count == 3) }

    @Test func replacesWholeWordsIgnoringCase() {
        #expect(g.apply("I like hear say and Hear Say.") == "I like Hearsay and Hearsay.")
        #expect(g.apply("Fluid Audio rocks") == "FluidAudio rocks")
        #expect(g.apply("hear sayings") == "hear sayings")
    }

    @Test func preservesCaseForLowercaseReplacements() {
        #expect(g.apply("reece, Reece, REECE, reeces") == "priya, Priya, PRIYA, reeces")
    }

    @Test func appliesToTranscript() {
        let (_, t) = TestSupport.smallMeeting()
        let fixed = Glossary(text: "hello => Howdy").apply(to: t)
        #expect(fixed.utterances[1].text == "Howdy, Howdy again.")
        #expect(fixed.utterances[0] == t.utterances[0])
    }
}
