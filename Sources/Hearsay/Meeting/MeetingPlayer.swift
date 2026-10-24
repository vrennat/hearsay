@preconcurrency import AVFoundation
import Foundation
import HearsayCore
import Observation

/// Playback for one meeting: a single `AVPlayer` over an `AVMutableComposition` that inserts each
/// stream at its `startOffset`, so composition time is meeting time and a turn's `start` seeks straight
/// to it. Mic / Call / Both is an `AVMutableAudioMix` that mutes tracks.
@MainActor @Observable
final class MeetingPlayer {
    enum Mix: String, CaseIterable { case both = "Both", mic = "Mic", call = "Call" }

    private let log = HSLog("player")
    let player = AVPlayer()
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var available: [StreamKind] = []
    var mix: Mix = .both { didSet { applyMix() } }
    @ObservationIgnored private var tracks: [(StreamKind, AVMutableCompositionTrack)] = []
    @ObservationIgnored private var observer: Any?
    /// Decrypted copies of `.enc` streams (0600, app caches); deleted in `tearDown`.
    @ObservationIgnored private var tempFiles: [URL] = []

    /// Builds the composition. Streams whose file is missing or unreadable are skipped and logged.
    static func load(meeting: Meeting, folder: URL) async -> MeetingPlayer? {
        let composition = AVMutableComposition()
        var tracks: [(StreamKind, AVMutableCompositionTrack)] = []
        var temps: [URL] = []
        for s in meeting.streams {
            var url = folder.appendingPathComponent(s.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                if EncryptedFile.isEncrypted(url) {
                    url = try decryptForPlayback(url)
                    temps.append(url)
                }
                let asset = AVURLAsset(url: url)
                guard let src = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                let range = try await src.load(.timeRange)
                guard let dst = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                let at = CMTime(seconds: max(0, s.startOffset), preferredTimescale: 48_000)
                try dst.insertTimeRange(range, of: src, at: at)
                tracks.append((s.kind, dst))
            } catch {
                HSLog("player").error("Cannot load \(s.file) of \(meeting.id): \(error)")
            }
        }
        guard !tracks.isEmpty else {
            for t in temps { try? FileManager.default.removeItem(at: t) }
            return nil
        }
        let p = MeetingPlayer()
        p.tracks = tracks
        p.tempFiles = temps
        p.available = Array(Set(tracks.map(\.0))).sorted { $0.rawValue < $1.rawValue }
        p.duration = composition.duration.seconds
        let item = AVPlayerItem(asset: composition)
        p.player.replaceCurrentItem(with: item)
        p.applyMix()
        p.observe()
        p.log.info("Player for \(meeting.id): \(tracks.count) tracks, \(String(format: "%.1f", p.duration)) s")
        return p
    }

    private func observe() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 5), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = t.seconds.isFinite ? t.seconds : 0
                self.isPlaying = self.player.rate != 0
            }
        }
    }

    private func applyMix() {
        let params = tracks.map { kind, track -> AVMutableAudioMixInputParameters in
            let p = AVMutableAudioMixInputParameters(track: track)
            let on: Bool
            switch mix {
            case .both: on = true
            case .mic: on = kind == .mic
            case .call: on = kind == .system
            }
            p.setVolume(on ? 1 : 0, at: .zero)
            return p
        }
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = params
        player.currentItem?.audioMix = audioMix
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        if time >= duration - 0.05 { seek(to: 0) }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let t = min(max(0, seconds), duration)
        time = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Composition segments per track as (kind, start, end) in meeting seconds; for the log and checks.
    var segments: [(StreamKind, Double, Double)] {
        tracks.flatMap { kind, t in
            t.segments.filter { !$0.isEmpty }.map { seg in
                (kind, seg.timeMapping.target.start.seconds, seg.timeMapping.target.end.seconds)
            }
        }
    }

    func tearDown() {
        pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.replaceCurrentItem(with: nil)
        for t in tempFiles { try? FileManager.default.removeItem(at: t) }
        tempFiles = []
    }

    /// Removes decrypted playback copies a crash left behind. Called at launch.
    static func sweepPlaybackCopies() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        try? FileManager.default.removeItem(at: caches.appendingPathComponent("com.tannervass.hearsay/playback"))
    }

    /// Spec: playback decrypts to a temp file under the app's caches with 0600, deleted on close.
    private static func decryptForPlayback(_ url: URL) throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = caches.appendingPathComponent("com.tannervass.hearsay/playback", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let plainName = url.deletingPathExtension().lastPathComponent
        let out = dir.appendingPathComponent("\(UUID().uuidString)-\(plainName)")
        try EncryptedFile.decryptFile(url, to: out, key: AudioKey.existing())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: out.path)
        return out
    }
}
