import AVFoundation
import CryptoKit
import XCTest
@testable import HearsayCore

final class EncryptedFileTests: XCTestCase {
    let key = SymmetricKey(size: .bits256)

    private func bytes(_ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }) }

    func testRoundTripsAtChunkBoundaries() throws {
        let c = EncryptedFile.chunkSize
        for n in [0, 1, c - 1, c, c + 1, 2 * c, 2 * c + 5] {
            let plain = bytes(n)
            let sealed = try EncryptedFile.encrypt(plain, key: key)
            XCTAssertEqual(sealed.prefix(4), Data("HSE1".utf8))
            let chunks = max(1, (n + c - 1) / c)
            XCTAssertEqual(sealed.count, 4 + 12 + n + 16 * chunks, "size \(n)")
            XCTAssertEqual(try EncryptedFile.decrypt(sealed, key: key), plain, "size \(n)")
        }
    }

    func testStreamingFilesMatchInMemory() throws {
        let root = try TestSupport.tempRoot()
        let plain = bytes(3 * EncryptedFile.chunkSize + 123)
        let src = root.appendingPathComponent("a.bin"), enc = root.appendingPathComponent("a.bin.enc"), back = root.appendingPathComponent("b.bin")
        try plain.write(to: src)
        try EncryptedFile.encryptFile(src, to: enc, key: key)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: enc.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try EncryptedFile.decryptFile(enc, key: key), plain)
        try EncryptedFile.decryptFile(enc, to: back, key: key)
        XCTAssertEqual(try Data(contentsOf: back), plain)
    }

    func testTamperWrongKeyAndTruncationFail() throws {
        let c = EncryptedFile.chunkSize
        let sealed = try EncryptedFile.encrypt(bytes(2 * c + 10), key: key)
        var flipped = sealed
        flipped[20] ^= 0x01
        XCTAssertThrowsError(try EncryptedFile.decrypt(flipped, key: key)) { XCTAssert($0 is CryptoError) }
        var tagFlip = sealed
        tagFlip[tagFlip.count - 1] ^= 0x80
        XCTAssertThrowsError(try EncryptedFile.decrypt(tagFlip, key: key))
        XCTAssertThrowsError(try EncryptedFile.decrypt(sealed, key: SymmetricKey(size: .bits256)))
        // Dropping the last chunk exactly at a chunk boundary: the new last chunk was not sealed as final.
        let twoChunks = sealed.prefix(16 + 2 * (c + 16))
        XCTAssertThrowsError(try EncryptedFile.decrypt(Data(twoChunks), key: key))
        // Swapping two chunks breaks the per-chunk nonce.
        let h = sealed.prefix(16), a = sealed.subdata(in: 16..<(16 + c + 16)), b = sealed.subdata(in: (16 + c + 16)..<(16 + 2 * (c + 16)))
        XCTAssertThrowsError(try EncryptedFile.decrypt(h + b + a + sealed.suffix(from: 16 + 2 * (c + 16)), key: key))
        XCTAssertThrowsError(try EncryptedFile.decrypt(sealed + Data([0]), key: key))  // trailing bytes
        XCTAssertThrowsError(try EncryptedFile.decrypt(Data("plain text".utf8), key: key)) {
            XCTAssertEqual($0 as? CryptoError, .notEncrypted)
        }
    }

    func testChunkNoncesDiffer() throws {
        let base = Data(repeating: 0xAB, count: 12)
        XCTAssertNotEqual(Data(try EncryptedFile.nonce(base, 0)), Data(try EncryptedFile.nonce(base, 1)))
        XCTAssertEqual(Data(try EncryptedFile.nonce(base, 0)), base)
    }
}

final class AudioEncryptionTests: XCTestCase {
    override func setUp() { AudioKey.store = InMemoryAudioKeyStore() }

    private func tone(_ url: URL, seconds: Double = 2, rate: Double = 48_000) throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(rate * seconds))!
        buf.frameLength = buf.frameCapacity
        for ch in 0..<2 { for i in 0..<Int(buf.frameLength) { buf.floatChannelData![ch][i] = 0.3 * sin(Float(i) * 0.05) } }
        try f.write(from: buf)
    }

    private func meeting(_ store: MeetingStore, _ id: String, file: String) throws -> URL {
        let audio = store.folder(id).appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try store.saveMeeting(Meeting(id: id, title: "E", startedAt: Date(), status: .done,
                                      streams: [AudioStream(kind: .mic, file: "audio/\(file)")]))
        return store.folder(id).appendingPathComponent("audio/\(file)")
    }

    func testEncryptedCAFDecodesLikePlainAndDecryptsBack() throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let id = "2026-10-22 0900 E"
        let caf = try meeting(store, id, file: "mic.caf")
        try tone(caf)
        let plainSamples = try AudioLoader.loadMono16k(caf)
        let original = try Data(contentsOf: caf)
        XCTAssertEqual(try AudioVault.encryptMeeting(id, store: store), 1)
        XCTAssertEqual(try store.loadMeeting(id).streams.map(\.file), ["audio/mic.caf.enc"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: caf.path))
        let enc = store.folder(id).appendingPathComponent("audio/mic.caf.enc")
        XCTAssertEqual(try Data(contentsOf: enc).prefix(4), Data("HSE1".utf8))
        let encSamples = try AudioLoader.loadMono16k(enc)
        XCTAssertEqual(encSamples.count, plainSamples.count)
        XCTAssertEqual(encSamples, plainSamples)
        // Tracks (the pipeline's reader) goes through the same path.
        XCTAssertEqual(try Track.load(try store.loadMeeting(id), store: store).first?.samples.count, plainSamples.count)

        XCTAssertEqual(try AudioVault.decryptMeeting(id, store: store), 1)
        XCTAssertEqual(try Data(contentsOf: caf), original)
        XCTAssertEqual(try store.loadMeeting(id).streams.map(\.file), ["audio/mic.caf"])
    }

    // MARK: Crash recovery (launch sweep), each test leaves files as a crash at one step would.

    private func exists(_ store: MeetingStore, _ id: String, _ rel: String) -> Bool {
        FileManager.default.fileExists(atPath: store.folder(id).appendingPathComponent(rel).path)
    }

    /// Crash after repointing meeting.json at the .enc, before deleting the plain source.
    func testSweepRemovesPlainWhoseEncIsReferenced() throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let id = "2026-10-22 0900 S1"
        let caf = try meeting(store, id, file: "mic.caf")
        try tone(caf)
        try EncryptedFile.encryptFile(caf, to: caf.appendingPathExtension("enc"), key: AudioKey.getOrCreate())
        var m = try store.loadMeeting(id); m.streams[0].file = "audio/mic.caf.enc"; try store.saveMeeting(m)
        XCTAssertEqual(AudioVault.sweep(store: store, encrypt: true), 1)
        XCTAssertFalse(exists(store, id, "audio/mic.caf"))
        XCTAssertTrue(exists(store, id, "audio/mic.caf.enc"))
        XCTAssertEqual(try store.loadMeeting(id).streams.map(\.file), ["audio/mic.caf.enc"])
        XCTAssertEqual(AudioVault.sweep(store: store, encrypt: true), 0)  // idempotent
    }

    /// Crash in compression after repointing at the .m4a.enc, before deleting the source CAF.
    func testSweepRemovesTheCAFACompressionReplaced() throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let id = "2026-10-22 0900 S2"
        let caf = try meeting(store, id, file: "mic.caf")
        try tone(caf)
        try EncryptedFile.encryptFile(caf, to: caf.deletingLastPathComponent().appendingPathComponent("mic.m4a.enc"), key: AudioKey.getOrCreate())
        try Data("other".utf8).write(to: caf.deletingLastPathComponent().appendingPathComponent("system.caf"))
        var m = try store.loadMeeting(id); m.streams[0].file = "audio/mic.m4a.enc"; try store.saveMeeting(m)
        AudioVault.sweep(store: store, encrypt: true)
        XCTAssertFalse(exists(store, id, "audio/mic.caf"))
        XCTAssertTrue(exists(store, id, "audio/mic.m4a.enc"))
        XCTAssertTrue(exists(store, id, "audio/system.caf"), "a different stream's file is not touched")
    }

    /// Crash after the .enc was renamed into place, before meeting.json was repointed.
    func testSweepFinishesAnUnpointedEncryption() throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let id = "2026-10-22 0900 S3"
        let caf = try meeting(store, id, file: "mic.caf")
        try tone(caf)
        let original = try Data(contentsOf: caf)
        let enc = caf.appendingPathExtension("enc")
        try EncryptedFile.encryptFile(caf, to: enc, key: AudioKey.getOrCreate())
        XCTAssertEqual(AudioVault.sweep(store: store, encrypt: true), 1)
        XCTAssertEqual(try store.loadMeeting(id).streams.map(\.file), ["audio/mic.caf.enc"])
        XCTAssertFalse(exists(store, id, "audio/mic.caf"))
        XCTAssertEqual(try EncryptedFile.decryptFile(enc, key: AudioKey.existing()), original)
    }

    /// An .enc that does not decrypt (cut short) is removed and the plain, referenced file kept.
    func testSweepDropsABrokenEncAndKeepsThePlainFile() throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let id = "2026-10-22 0900 S4"
        let caf = try meeting(store, id, file: "mic.caf")
        try tone(caf)
        let enc = caf.appendingPathExtension("enc")
        try EncryptedFile.encryptFile(caf, to: enc, key: AudioKey.getOrCreate())
        let sealed = try Data(contentsOf: enc)
        try sealed.prefix(sealed.count - 20).write(to: enc)
        AudioVault.sweep(store: store, encrypt: true)
        XCTAssertFalse(exists(store, id, "audio/mic.caf.enc"))
        XCTAssertTrue(exists(store, id, "audio/mic.caf"))
        XCTAssertEqual(try store.loadMeeting(id).streams.map(\.file), ["audio/mic.caf"])
    }

    /// Crash in decryption after repointing at the plain file: the stale .enc goes, the plain stays.
    func testSweepWithEncryptionOffRemovesTheLeftoverEnc() throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let id = "2026-10-22 0900 S5"
        let caf = try meeting(store, id, file: "mic.caf")
        try tone(caf)
        try EncryptedFile.encryptFile(caf, to: caf.appendingPathExtension("enc"), key: AudioKey.getOrCreate())
        AudioVault.sweep(store: store, encrypt: false)
        XCTAssertFalse(exists(store, id, "audio/mic.caf.enc"))
        XCTAssertTrue(exists(store, id, "audio/mic.caf"))
    }

    func testSweepLeavesRecordingAndHealthyMeetingsAlone() throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let rec = "2026-10-22 0900 S6", ok = "2026-10-22 0901 S7"
        let caf = try meeting(store, rec, file: "mic.caf")
        try tone(caf)
        try EncryptedFile.encryptFile(caf, to: caf.appendingPathExtension("enc"), key: AudioKey.getOrCreate())
        var m = try store.loadMeeting(rec); m.status = .recording; try store.saveMeeting(m)
        try tone(try meeting(store, ok, file: "mic.caf"))
        XCTAssertEqual(AudioVault.sweep(store: store, encrypt: true), 0)
        XCTAssertTrue(exists(store, rec, "audio/mic.caf"))
        XCTAssertTrue(exists(store, rec, "audio/mic.caf.enc"))
        XCTAssertTrue(exists(store, ok, "audio/mic.caf"))
    }

    // MARK: Conversion vs. the pipeline

    /// The queue gets meeting B while the toggle's conversion is working on A: B is skipped, not raced.
    func testConvertAllRechecksBusyPerMeeting() throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let a = "2026-10-22 0900 A", b = "2026-10-22 0901 B"
        try tone(try meeting(store, a, file: "mic.caf"))
        try tone(try meeting(store, b, file: "mic.caf"))
        var queued: Set<String> = []
        var asked: [String] = []
        let n = AudioVault.convertAll(store: store, encrypt: true, lock: MeetingLock()) { id in
            asked.append(id)
            if id == a { queued.insert(b) }  // stub: the queue enqueues B while A is converting
            return queued.contains(id)
        }
        XCTAssertEqual(n, 1)
        XCTAssertTrue(asked.contains(b), "B was asked about after A started")
        XCTAssertEqual(try store.loadMeeting(a).streams.map(\.file), ["audio/mic.caf.enc"])
        XCTAssertEqual(try store.loadMeeting(b).streams.map(\.file), ["audio/mic.caf"])
        XCTAssertTrue(exists(store, b, "audio/mic.caf"))
    }

    /// A meeting the pipeline holds is skipped; a pipeline arriving mid-conversion waits for it.
    func testConvertAllAndThePipelineShareTheMeetingLock() async throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let a = "2026-10-22 0900 LA", b = "2026-10-22 0901 LB"
        try tone(try meeting(store, a, file: "mic.caf"))
        try tone(try meeting(store, b, file: "mic.caf"))
        let lock = MeetingLock()
        XCTAssertTrue(lock.tryAcquire(b))  // the pipeline is processing B
        let got = expectation(description: "pipeline acquired A")
        let order = OrderLog()
        let n = AudioVault.convertAll(store: store, encrypt: true, lock: lock) { id in
            if id == a, lock.isHeld(a), !order.started {
                order.started = true
                Task { await lock.acquire(a); order.append("pipeline"); lock.release(a); got.fulfill() }
                Thread.sleep(forTimeInterval: 0.2)  // give the waiter a chance to (wrongly) get in
            }
            return false
        }
        order.append("converted")
        XCTAssertEqual(n, 1)
        await fulfillment(of: [got], timeout: 5)
        XCTAssertEqual(order.events, ["converted", "pipeline"])
        XCTAssertEqual(try store.loadMeeting(b).streams.map(\.file), ["audio/mic.caf"], "held meeting skipped")
        lock.release(b)
    }

    func testMissingKeyIsAClearError() throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let id = "2026-10-22 0900 K"
        try tone(try meeting(store, id, file: "mic.caf"))
        try AudioVault.encryptMeeting(id, store: store)
        AudioKey.store = InMemoryAudioKeyStore()  // the Keychain item is gone
        XCTAssertThrowsError(try AudioLoader.loadMono16k(store.folder(id).appendingPathComponent("audio/mic.caf.enc"))) {
            XCTAssertEqual($0 as? CryptoError, .audioKeyMissing)
            XCTAssertTrue(String(describing: $0).contains("Keychain"))
        }
    }

    func testCompressWritesM4AEncAndReadsItBack() async throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let id = "2026-10-22 0900 M"
        try tone(try meeting(store, id, file: "mic.wav"), seconds: 3)
        let c1 = try await AudioCompressor.compressMeeting(id, store: store, encrypt: true)
        XCTAssertEqual(c1, 1)
        XCTAssertEqual(try store.loadMeeting(id).streams.map(\.file), ["audio/mic.m4a.enc"])
        let audio = store.folder(id).appendingPathComponent("audio")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: audio.path).sorted(), ["mic.m4a.enc"])
        let samples = try AudioLoader.loadMono16k(audio.appendingPathComponent("mic.m4a.enc"))
        XCTAssertEqual(Double(samples.count) / AudioLoader.sampleRate, 3, accuracy: 0.5)
        // Already .m4a.enc: left alone.
        let c0 = try await AudioCompressor.compressMeeting(id, store: store, encrypt: true)
        XCTAssertEqual(c0, 0)
    }

    func testCompressAnEncryptedCAFStaysEncrypted() async throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let id = "2026-10-22 0900 N"
        try tone(try meeting(store, id, file: "mic.caf"))
        try AudioVault.encryptMeeting(id, store: store)
        let c1 = try await AudioCompressor.compressMeeting(id, store: store, encrypt: false)
        XCTAssertEqual(c1, 1)
        XCTAssertEqual(try store.loadMeeting(id).streams.map(\.file), ["audio/mic.m4a.enc"])
    }

    func testRetentionRemovesEncryptedAudio() throws {
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let id = "2026-01-01 0900 R"
        let now = Date()
        let file = try meeting(store, id, file: "mic.caf")
        try tone(file, seconds: 0.5)
        var m = try store.loadMeeting(id)
        m.startedAt = now.addingTimeInterval(-3 * 86_400)
        try store.saveMeeting(m)
        try AudioVault.encryptMeeting(id, store: store)
        try TestVault.lock(store)
        try store.saveTranscript(Transcript(engine: "parakeet", processedAt: now, speakers: [], utterances: []), id: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(id).appendingPathComponent("transcript.json").path))
        let p = RetentionPlan.make(store: store, now: now, keepAudioDays: 1, keepTranscriptDays: 0)
        XCTAssertEqual(p.items.map(\.action), [.removeAudio])
        XCTAssertEqual(Retention.apply(p, store: store, now: now), [id])
        XCTAssertNotNil(try store.loadMeeting(id).audioRemovedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(id).appendingPathComponent("audio").path))
    }
}

enum TestVault {
    static let password = "correct horse battery staple"
    /// Locks with few PBKDF2 iterations so tests stay fast; the format is the same.
    @discardableResult
    static func lock(_ store: MeetingStore) throws -> Int {
        try TranscriptVault.lock(store: store, password: password, iterations: 1_000)
    }
}

final class TranscriptVaultTests: XCTestCase {
    func testDerivationIsDeterministicAndSaltDependent() {
        let salt = Data(repeating: 1, count: 16)
        let a = try! TranscriptVault.deriveKey(password: "pw", salt: salt, iterations: 1_000)
        let b = try! TranscriptVault.deriveKey(password: "pw", salt: salt, iterations: 1_000)
        let c = try! TranscriptVault.deriveKey(password: "pw", salt: Data(repeating: 2, count: 16), iterations: 1_000)
        let raw = { (k: SymmetricKey) in k.withUnsafeBytes { Data($0) } }
        XCTAssertEqual(raw(a), raw(b))
        XCTAssertNotEqual(raw(a), raw(c))
        XCTAssertEqual(raw(a).count, 32)
    }

    func testLockUnlockRoundTripsEveryFile() throws {
        let store = try TestSupport.rootWithFixture()
        let id = TestSupport.fixtureID
        try IndexRenderer.reindex(store: store)
        let folder = store.folder(id)
        var before: [String: Data] = [:]
        for name in TranscriptVault.protectedFiles {
            if let d = try? Data(contentsOf: folder.appendingPathComponent(name)) { before[name] = d }
        }
        XCTAssertTrue(before.keys.contains("transcript.md"))
        XCTAssertTrue(before.keys.contains("live.md"))
        let meetingBefore = try Data(contentsOf: folder.appendingPathComponent("meeting.json"))
        let lines = TranscriptLines.load(store: store, id: id)

        XCTAssertEqual(try TestVault.lock(store), before.count)
        for name in before.keys {
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), name)
            let sealed = try Data(contentsOf: folder.appendingPathComponent(name + ".enc"))
            XCTAssertEqual(sealed.prefix(4), Data("HSE1".utf8))
        }
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("meeting.json")), meetingBefore)
        // Index: titles and dates only.
        let jsonl = try String(contentsOf: store.root.appendingPathComponent("index.jsonl"), encoding: .utf8)
        XCTAssertTrue(jsonl.contains("\"speakers\":[]"))
        XCTAssertTrue(jsonl.contains("transcript.md.enc"))
        // Every reader works through the store while unlocked.
        XCTAssertNotNil(try store.loadTranscript(id))
        XCTAssertEqual(TranscriptLines.load(store: store, id: id), lines)
        XCTAssertTrue(try TranscriptRenderer.write(store: store, id: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.md").path))

        // Another process without the password.
        TranscriptKeys.set(nil, for: store.root)
        XCTAssertThrowsError(try store.loadTranscript(id)) { XCTAssertEqual($0 as? CryptoError, .transcriptsLocked) }
        XCTAssertNoThrow(try store.loadMeeting(id))
        XCTAssertThrowsError(try TranscriptVault.unlock(root: store.root, password: "nope")) {
            XCTAssertEqual($0 as? CryptoError, .wrongPassword)
        }

        let exportDir = try TestSupport.tempRoot()
        try TranscriptVault.unlock(root: store.root, password: TestVault.password)
        let out = try TranscriptVault.export(store: store, id: id, to: exportDir)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("transcript.json")), before["transcript.json"])

        TranscriptKeys.set(nil, for: store.root)
        XCTAssertEqual(try TranscriptVault.unlockAll(store: store, password: TestVault.password), before.count)
        for (name, data) in before where !name.hasSuffix(".md") {
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), data, name)
        }
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("live.md")), before["live.md"])
        XCTAssertFalse(TranscriptVault.isEnabled(root: store.root))
    }

    func testDamagedVaultFailsClosed() throws {
        let store = try TestSupport.rootWithFixture()
        try TestVault.lock(store)
        TranscriptKeys.set(nil, for: store.root)
        try Data("{trunc".utf8).write(to: TranscriptVault.url(root: store.root))
        XCTAssertTrue(store.transcriptsEncrypted)
        XCTAssertThrowsError(try store.saveCleanup(Cleanup(sourceProcessedAt: Date(), utterances: []), id: TestSupport.fixtureID))
        XCTAssertThrowsError(try TranscriptVault.unlock(root: store.root, password: TestVault.password))
    }

    func testAudioEncryptFailureAfterDoneKeepsStatus() async throws {
        final class Failing: AudioKeyStore, @unchecked Sendable {
            func load() throws -> SymmetricKey? { throw CryptoError.keychain(-25308) }
            func save(_ key: SymmetricKey) throws { throw CryptoError.keychain(-25308) }
        }
        AudioKey.store = Failing()
        defer { AudioKey.store = InMemoryAudioKeyStore() }
        let store = MeetingStore(root: try TestSupport.tempRoot())
        let id = "2026-10-22 0900 F"
        try FileManager.default.createDirectory(at: store.folder(id).appendingPathComponent("audio"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: store.folder(id).appendingPathComponent("audio/mic.caf"))
        try store.saveMeeting(Meeting(id: id, title: "F", startedAt: Date(), status: .done, streams: [AudioStream(kind: .mic, file: "audio/mic.caf")]))
        XCTAssertThrowsError(try AudioVault.encryptMeeting(id, store: store))
        XCTAssertEqual(try store.loadMeeting(id).status, .done)
        XCTAssertEqual(try store.loadMeeting(id).streams.map(\.file), ["audio/mic.caf"])
    }

    func testChangePasswordReencrypts() throws {
        let store = try TestSupport.rootWithFixture()
        try TestVault.lock(store)
        try TranscriptVault.changePassword(store: store, old: TestVault.password, new: "new one", iterations: 1_000)
        TranscriptKeys.set(nil, for: store.root)
        XCTAssertThrowsError(try TranscriptVault.unlock(root: store.root, password: TestVault.password))
        try TranscriptVault.unlock(root: store.root, password: "new one")
        XCTAssertNotNil(try store.loadTranscript(TestSupport.fixtureID))
    }

    func testPipelineRefusesWhileLockedWithoutTouchingStatus() async throws {
        let store = try TestSupport.rootWithFixture()
        try TestVault.lock(store)
        TranscriptKeys.set(nil, for: store.root)
        let status = try store.loadMeeting(TestSupport.fixtureID).status
        do {
            try await ProcessPipeline.process(meetingID: TestSupport.fixtureID, store: store)
            XCTFail("expected locked")
        } catch {
            XCTAssertEqual(error as? CryptoError, .transcriptsLocked)
        }
        XCTAssertEqual(try store.loadMeeting(TestSupport.fixtureID).status, status)
    }
}

private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    var started = false
    private var list: [String] = []
    func append(_ e: String) { lock.lock(); list.append(e); lock.unlock() }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return list }
}
