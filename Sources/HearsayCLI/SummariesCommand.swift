import ArgumentParser
import Foundation
import HearsayCore

struct SummariesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summaries",
        abstract: "One-line on-device summary per speaker, biggest talkers first. A naming hint; never saved.")
    @Argument(help: "Meeting id (folder name).") var id: String
    @OptionGroup var root: RootOption

    mutating func run() async throws {
        let store = root.store
        let meeting = try store.loadMeeting(id)
        guard let transcript = try store.loadTranscript(id) else { throw ValidationError("\(id) has no transcript.json yet") }
        if let reason = SpeakerSummaries.unavailableReason() {
            print("Summaries unavailable: \(reason)")
            return
        }
        let inputs = SpeakerSummaries.inputs(transcript)
        if inputs.isEmpty {
            print("No speaker has \(SpeakerSummaries.minimumWords)+ words to summarize.")
            return
        }
        let start = Date()
        for line in try await SpeakerSummaries.summarize(transcript) {
            let name = meeting.speakerNames[line.speaker] ?? transcript.speaker(line.speaker)?.defaultLabel ?? line.speaker
            print("\(line.speaker)\t\(name)\t\(line.text)")
        }
        HSLog("cli").info("summaries \(id): \(inputs.count) speakers in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
    }
}
