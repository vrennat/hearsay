import Foundation

/// Recording encryption over a meeting's `meeting.json` streams (spec amendment "Encryption at
/// rest", recordings). The plain file is deleted only after `meeting.json` points at its replacement.
public enum AudioVault {
    private static let log = HearsayCore.logger("audio-vault")

    /// Encrypts every plain stream file to `<file>.enc`. Returns the number encrypted.
    @discardableResult
    public static func encryptMeeting(_ id: String, store: MeetingStore) throws -> Int {
        try convert(id, store: store, encrypt: true)
    }

    /// Writes each stream of a meeting to `dest`, decrypted (`.enc` dropped from the name), leaving the
    /// meeting untouched. `hearsay export --audio`. Returns the files written.
    public static func export(_ id: String, store: MeetingStore, to dest: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        return try store.loadMeeting(id).streams.map { s in
            let src = store.folder(id).appendingPathComponent(s.file)
            let isEnc = src.pathExtension == "enc"
            let target = dest.appendingPathComponent(isEnc ? src.deletingPathExtension().lastPathComponent : src.lastPathComponent)
            try? FileManager.default.removeItem(at: target)
            if isEnc { try EncryptedFile.decryptFile(src, to: target, key: AudioKey.existing()) }
            else { try FileManager.default.copyItem(at: src, to: target) }
            return target
        }
    }

    /// Decrypts every `.enc` stream back to its plain file (Settings: recordings encryption off).
    @discardableResult
    public static func decryptMeeting(_ id: String, store: MeetingStore) throws -> Int {
        try convert(id, store: store, encrypt: false)
    }

    /// Every meeting not recording or processing for which `isBusy` is false. `isBusy` is asked
    /// per meeting immediately before it is touched, under `MeetingLock`, and the meeting's status is
    /// re-read there, so a meeting queued mid-run is skipped rather than raced. Errors are logged per meeting.
    @discardableResult
    public static func convertAll(store: MeetingStore, encrypt: Bool, lock: MeetingLock = .shared,
                                  isBusy: (String) -> Bool = { _ in false }) -> Int {
        var n = 0
        for id in store.loadAllMeetings().map(\.id) {
            guard !isBusy(id), lock.tryAcquire(id) else { continue }
            defer { lock.release(id) }
            guard !isBusy(id), let m = try? store.loadMeeting(id), m.status != .recording, m.status != .processing else { continue }
            do { n += try convert(id, store: store, encrypt: encrypt) } catch {
                log.error("\(encrypt ? "Encrypting" : "Decrypting", privacy: .public) audio of \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        return n
    }

    /// Launch sweep for a conversion or compression cut short by a crash. For each meeting not recording:
    /// a stream pointing at `<x>.enc` loses any plain file of the same stem that `meeting.json` does not
    /// reference (`<x>`, or the `.caf` a compression replaced); a stream pointing at plain `<x>` whose
    /// `<x>.enc` exists is finished when `encrypt` (repointed once the `.enc` decrypts, then the plain
    /// file deleted; an `.enc` that does not decrypt is deleted) and otherwise loses the leftover `.enc`.
    /// Returns the number of files removed.
    @discardableResult
    public static func sweep(store: MeetingStore, encrypt: Bool) -> Int {
        let fm = FileManager.default
        var removed = 0
        for m in store.loadAllMeetings() where m.status != .recording {
            guard MeetingLock.shared.tryAcquire(m.id) else { continue }
            defer { MeetingLock.shared.release(m.id) }
            guard var meeting = try? store.loadMeeting(m.id) else { continue }
            let folder = store.folder(m.id)
            func remove(_ url: URL) {
                do { try fm.removeItem(at: url); removed += 1; log.info("Swept \(url.lastPathComponent, privacy: .public) in \(m.id, privacy: .public)") }
                catch { log.error("Sweep cannot remove \(url.path, privacy: .public): \(String(describing: error), privacy: .public)") }
            }
            // Finish or undo a half-done encryption first, so the stale-sibling pass sees the final names.
            for (i, s) in meeting.streams.enumerated() where !EncryptedFile.isEncrypted(URL(fileURLWithPath: s.file)) {
                let plain = folder.appendingPathComponent(s.file), twin = folder.appendingPathComponent(s.file + "." + EncryptedFile.suffix)
                guard fm.fileExists(atPath: plain.path), fm.fileExists(atPath: twin.path) else { continue }
                guard encrypt else { remove(twin); continue }
                do {
                    _ = try EncryptedFile.decryptFile(twin, key: AudioKey.existing())
                } catch CryptoError.audioKeyMissing {
                    continue
                } catch {
                    remove(twin); continue
                }
                meeting.streams[i].file = s.file + "." + EncryptedFile.suffix
                do { try store.saveMeeting(meeting) } catch {
                    log.error("Sweep cannot repoint \(m.id, privacy: .public): \(String(describing: error), privacy: .public)"); continue
                }
                remove(plain)
            }
            let referenced = Set(meeting.streams.map(\.file))
            for s in meeting.streams where EncryptedFile.isEncrypted(URL(fileURLWithPath: s.file)) {
                let rel = s.file as NSString
                let dir = rel.deletingLastPathComponent
                let stem = rel.lastPathComponent.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
                guard !stem.isEmpty, let names = try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent(dir).path) else { continue }
                for name in names where name.split(separator: ".", maxSplits: 1).first.map(String.init) == stem && !name.hasPrefix(".") {
                    let r = (dir as NSString).appendingPathComponent(name)
                    guard !referenced.contains(r), !EncryptedFile.isEncrypted(URL(fileURLWithPath: name)) else { continue }
                    remove(folder.appendingPathComponent(r))
                }
            }
        }
        return removed
    }

    static func convert(_ id: String, store: MeetingStore, encrypt: Bool) throws -> Int {
        var meeting = try store.loadMeeting(id)
        let folder = store.folder(id)
        let fm = FileManager.default
        var n = 0
        for (i, s) in meeting.streams.enumerated() {
            let src = folder.appendingPathComponent(s.file)
            guard fm.fileExists(atPath: src.path), EncryptedFile.isEncrypted(src) != encrypt else { continue }
            let rel = encrypt ? s.file + "." + EncryptedFile.suffix : (s.file as NSString).deletingPathExtension
            let dst = folder.appendingPathComponent(rel)
            if encrypt {
                try EncryptedFile.encryptFile(src, to: dst, key: AudioKey.getOrCreate())
            } else {
                try EncryptedFile.decryptFile(src, to: dst, key: AudioKey.existing())
            }
            meeting.streams[i].file = rel
            try store.saveMeeting(meeting)  // repoint before deleting
            try fm.removeItem(at: src)
            n += 1
        }
        return n
    }

    /// A private 0700 scratch folder for the rare plaintext temp file (compressing an encrypted CAF).
    static func privateTemp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hearsay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }
}
