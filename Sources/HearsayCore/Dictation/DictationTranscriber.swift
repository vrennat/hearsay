@preconcurrency import AVFoundation
import FluidAudio
import Foundation

public struct DictationResult: Sendable, Equatable {
    /// Text to paste: Parakeet, then glossary, then filler removal when cleanup is on.
    public let text: String
    /// Parakeet's text before glossary and cleanup.
    public let rawText: String
    public let clipSeconds: Double
    /// Wall time from `transcribe` call to result.
    public let seconds: Double
}

/// Dictation path (spec, Dictation): its own streaming Parakeet for the bubble and its own batch
/// Parakeet for the final text, so a meeting being transcribed never blocks it. Saves nothing; logs
/// lengths and timings only.
public actor DictationTranscriber {
    public static let minimumClipSeconds = 0.3
    private static let log = HearsayCore.logger("dictation")

    private let batch = ParakeetTranscriber()
    private var streaming: StreamingUnifiedAsrManager?
    private var streamingActive = false
    public var glossary: Glossary
    public var cleanup: Bool

    public init(glossary: Glossary = Glossary(entries: []), cleanup: Bool = false) {
        self.glossary = glossary; self.cleanup = cleanup
    }

    public func configure(glossary: Glossary, cleanup: Bool) { self.glossary = glossary; self.cleanup = cleanup }

    /// Loads both models now (otherwise the first press pays for it).
    public func prepare() async throws {
        try await batch.load()
        _ = try await streamingEngine()
    }

    /// Final text for a finished 16 kHz mono clip. Clips under 0.3 s return empty text.
    public func transcribe(_ clip: [Float]) async throws -> DictationResult {
        let start = Date()
        let clipSeconds = Double(clip.count) / 16_000
        guard clipSeconds >= Self.minimumClipSeconds else {
            return DictationResult(text: "", rawText: "", clipSeconds: clipSeconds, seconds: 0)
        }
        let raw = try await batch.transcribe(clip).text.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = glossary.apply(raw)
        if cleanup { text = TextCleaner.clean(text) }
        let elapsed = Date().timeIntervalSince(start)
        Self.log.info("Dictation \(clipSeconds, format: .fixed(precision: 2))s clip -> \(text.count) chars in \(elapsed, format: .fixed(precision: 3))s")
        return DictationResult(text: text, rawText: raw, clipSeconds: clipSeconds, seconds: elapsed)
    }

    // MARK: Streaming bubble

    /// Starts a streaming session; `onPartial` gets the whole running text (hop to the main actor for UI).
    public func startStreaming(onPartial: @escaping @Sendable (String) -> Void) async throws {
        let asr = try await streamingEngine()
        try await asr.reset()
        await asr.setPartialTranscriptCallback(onPartial)
        streamingActive = true
    }

    /// Appends 16 kHz mono samples to the streaming session and decodes what is complete.
    public func appendStreaming(_ samples: [Float]) async throws {
        guard streamingActive, let asr = streaming, !samples.isEmpty else { return }
        try await asr.appendAudio(LiveTranscriber.pcmBuffer(samples))
        try await asr.processBufferedAudio()
    }

    /// Ends the streaming session and returns its text. The final paste text comes from `transcribe`.
    @discardableResult
    public func endStreaming() async -> String {
        guard streamingActive, let asr = streaming else { return "" }
        streamingActive = false
        var text = await asr.getPartialTranscript()
        if let final = try? await asr.finish() { text = final }
        await asr.setPartialTranscriptCallback { _ in }
        return text
    }

    private func streamingEngine() async throws -> StreamingUnifiedAsrManager {
        if let streaming { return streaming }
        let asr = StreamingUnifiedAsrManager(config: UnifiedConfig(leftFrames: 70, chunkFrames: 7, rightFrames: 7))
        try await asr.loadModels()
        streaming = asr
        return asr
    }
}
