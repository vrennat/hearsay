import Foundation

/// `hearsay voices`: backfill voice embeddings and inferred names without re-transcribing.
/// Embeddings run first in every meeting so voiceprint samples exist before naming.
public enum VoiceBackfill {
    public struct Row: Sendable, Equatable {
        public let meetingID: String
        public let speaker: String
        public let label: String
        public let name: String?
        public let previousName: String?
        /// `voice`, `new voice` or `no voice`.
        public let voice: String
    }

    /// Returns the plan; with `apply`, writes `transcript.json` voices and `meeting.json` names
    /// (without changing `processedAt`) and reindexes. Meetings without a transcript are skipped;
    /// missing audio means no new embeddings for that meeting.
    public static func run(store: MeetingStore, ids: [String] = [], userName: String?, apply: Bool,
                           embedder: VoiceEmbedder = PipelineEngines.shared.embedder) async throws -> [Row] {
        var plans: [(String, Meeting, Transcript, Transcript)] = []
        for id in ids.isEmpty ? store.listMeetingIDs() : ids {
            guard let m = try? store.loadMeeting(id), let t0 = try store.loadTranscript(id) else { continue }
            var t = t0
            if m.audioRemovedAt == nil, t.speakers.contains(where: { $0.voice == nil }) {
                let tracks = try Track.load(m, store: store)
                try await SpeakerIdentity.embed(&t, tracks: tracks, embedder: embedder)
                // Saved now so `Voiceprint.samples` (which reads the store) sees them while naming.
                if apply { try store.saveTranscript(t, id: id) }
            }
            plans.append((id, m, t0, t))
        }
        var rows: [Row] = []
        // Taken once, before any meeting is renamed: a guess made in this run never names the next meeting.
        let known = KnownVoices.samples(store: store)
        HSLog("voices").info("Known voices: \(known.count) samples, \(Set(known.map { $0.name.lowercased() }).count) names")
        for (id, m0, t0, t1) in plans {
            var m = m0, t = t1
            SpeakerIdentity.name(&t, meeting: &m, store: store, userName: userName, knownVoices: known)
            for s in t.speakers {
                let voice = s.voice == nil ? "no voice" : (t0.speaker(s.id)?.voice == nil ? "new voice" : "voice")
                rows.append(Row(meetingID: id, speaker: s.id, label: s.defaultLabel, name: m.speakerNames[s.id],
                                previousName: m0.speakerNames[s.id], voice: voice))
            }
            if apply {
                try store.saveTranscript(t, id: id)
                try store.saveMeeting(m)
            }
        }
        if apply { try IndexRenderer.reindex(store: store) }
        return rows
    }
}
