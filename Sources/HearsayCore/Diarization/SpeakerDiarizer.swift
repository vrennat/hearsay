import FluidAudio
import Foundation

/// FluidAudio's offline diarizer (pyannote community-1 segmentation + VBx clustering), run on one
/// track at a time. Segment times are seconds from the track's first sample.
public actor SpeakerDiarizer {
    public static let name = "fluidaudio-offline"
    private static let log = HearsayCore.logger("diarizer")
    private var manager: OfflineDiarizerManager?

    public init() {}

    public func load() async throws {
        guard manager == nil else { return }
        let m = OfflineDiarizerManager(config: .default)
        try await m.prepareModels()
        manager = m
    }

    public func diarize(_ samples: [Float]) async throws -> [DiarSegment] {
        try await load()
        guard let manager else { return [] }
        let result = try await manager.process(audio: samples)
        Self.log.info("Diarized \(samples.count) samples into \(result.segments.count) segments")
        return result.segments.map {
            DiarSegment(slot: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    }
}

/// CAM++ voice embeddings (192-d, L2-normalised) through FluidAudio. This is the only embedding
/// source for voice matching across meetings; the diarizer's 256-d WeSpeaker vectors are not
/// comparable with it.
public actor VoiceEmbedder {
    private var embedder: CampPlusEmbedder?

    public init() {}

    public func embed(_ samples: [Float]) async throws -> [Float] {
        if embedder == nil { embedder = try await CampPlusEmbedder.load() }
        return try await embedder!.embed(audio: samples)
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return -1 }
        return dot / (na * nb).squareRoot()
    }
}
