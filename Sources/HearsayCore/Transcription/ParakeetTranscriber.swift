import FluidAudio
import Foundation

public struct TranscribedWords: Sendable {
    public let text: String
    public let words: [Word]
}

/// Batch Parakeet TDT v3 through FluidAudio. Parakeet is the only engine (spec amendment 2026-10-23).
public actor ParakeetTranscriber {
    public static let engineName = "parakeet"
    private static let log = HearsayCore.logger("parakeet")

    private var manager: AsrManager?
    private var decoderLayers = 2

    public init() {}

    /// Loads the models, downloading them on first run (the app's only network use).
    public func load() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let m = AsrManager(config: .default)
        try await m.loadModels(models)
        decoderLayers = models.version.decoderLayers
        manager = m
        Self.log.info("Parakeet v3 loaded")
    }

    /// Transcribes mono 16 kHz samples. Word times are seconds from the first sample.
    public func transcribe(_ samples: [Float]) async throws -> TranscribedWords {
        try await load()
        guard let manager else { return TranscribedWords(text: "", words: []) }
        // FluidAudio rejects clips under 0.3 s; pad anything under 1 s with trailing silence.
        var input = samples
        if input.count < 16_000 { input += [Float](repeating: 0, count: 16_000 - input.count) }
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(input, decoderState: &state)
        let words = buildWordTimings(from: result.tokenTimings ?? [])
            .map { Word(text: $0.word, start: $0.startTime, end: $0.endTime) }
        Self.log.info("Transcribed \(samples.count) samples into \(words.count) words in \(result.processingTime)s")
        return TranscribedWords(text: result.text, words: words)
    }
}
