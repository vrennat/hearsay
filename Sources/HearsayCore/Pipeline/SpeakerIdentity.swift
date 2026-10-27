import Foundation

/// Voice embeddings and speaker naming, shared by `process` and `voices`.
public enum SpeakerIdentity {
    /// CAM++ needs some speech; under this the vector is noise and the speaker gets none.
    public static let minEmbedSeconds = 2.0

    /// Fills `voice` for every speaker without one (spec step 6).
    public static func embed(_ transcript: inout Transcript, tracks: [Track], embedder: VoiceEmbedder) async throws {
        for i in transcript.speakers.indices where transcript.speakers[i].voice == nil {
            let s = transcript.speakers[i]
            guard let track = tracks.first(where: { $0.kind == s.stream }) else { continue }
            let spans = Attribution.cleanSpans(for: s.id, in: transcript.utterances)
            var audio: [Float] = []
            for (a, b) in spans { audio += track.slice(a, b) }
            guard Double(audio.count) / AudioLoader.sampleRate >= minEmbedSeconds else { continue }
            transcript.speakers[i].voice = try await embedder.embed(audio)
        }
    }

    /// Runs naming, writes the names into `meeting.speakerNames` and labels the speaker that is you `Me`.
    /// `knownVoices`: pass samples taken once before a backfill run (so one meeting's guesses never feed
    /// the next, and transcripts are read once); nil reads them from the store.
    public static func name(_ transcript: inout Transcript, meeting: inout Meeting, store: MeetingStore, userName: String?,
                            knownVoices: [KnownVoices.Sample]? = nil) {
        let me = meeting.me ?? userName
        let live = (try? store.loadLive(meeting.id)).flatMap { $0 }.map { LiveNameMapper.map(live: $0, transcript: transcript) } ?? [:]
        let samples = me.map { Voiceprint.samples(store: store, firstName: Naming.firstName($0), excluding: meeting.id) } ?? []
        let out = Naming.name(Naming.Input(
            speakers: transcript.speakers, existing: meeting.speakerNames, live: live, me: me,
            attendees: meeting.attendees, title: meeting.title, voiceprintSamples: samples,
            knownVoices: knownVoices.map { $0.filter { $0.meetingID != meeting.id } } ?? KnownVoices.samples(store: store, excluding: meeting.id)))
        // Guesses from earlier runs stay guesses while the name is unchanged.
        let kept = meeting.inferredSpeakers.filter { out.names[$0] != nil && out.names[$0] == meeting.speakerNames[$0] }
        meeting.inferredSpeakers = Array(Set(kept).union(out.inferred)).sorted()
        meeting.speakerNames = out.names
        for i in transcript.speakers.indices {
            let s = transcript.speakers[i]
            let n = Int(s.id.split(separator: "-").last ?? "") ?? i + 1
            transcript.speakers[i].defaultLabel = s.id == out.me ? "Me" : Attribution.defaultLabel(stream: s.stream, number: n)
        }
    }
}
