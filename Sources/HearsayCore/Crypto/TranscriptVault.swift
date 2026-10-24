import CommonCrypto
import CryptoKit
import Foundation

/// `<root>/.hearsay-vault.json`: everything stored about the transcript password. The key is never
/// stored; the verifier is the `.enc` encryption of a known 32-byte constant.
public struct VaultFile: Codable, Sendable, Equatable {
    public var version = 1
    /// Transcripts are stored as `.enc` while true (`hearsay lock`); `hearsay unlock` sets it false.
    public var enabled: Bool
    public var salt: Data
    public var iterations: Int
    public var verifier: Data
}

/// Transcript encryption (spec amendment "Encryption at rest", transcripts): password-based and
/// unrecoverable. key = HKDF-SHA256(PBKDF2-HMAC-SHA256(password, salt, 600k)).
public enum TranscriptVault {
    public static let fileName = ".hearsay-vault.json"
    public static let iterations = 600_000
    static let verifierPlain = Data("hearsay transcript vault verify!".utf8)  // 32 bytes
    static let info = Data("hearsay transcripts v1".utf8)

    /// The files that are `.enc` while the vault is enabled. `meeting.json`, `index.*` stay plain.
    public static let protectedFiles = [
        MeetingStore.transcriptFile, "transcript.md", "transcript.raw.md", MeetingStore.cleanupFile,
        MeetingStore.liveJSONFile, MeetingStore.liveMarkdownFile,
    ]

    public static func url(root: URL) -> URL { root.appendingPathComponent(fileName) }

    /// Serializes vault changes (lock, unlock, password change) with every protected write, so a
    /// writer never pairs the old key or flag with the new vault. Recursive: lock reindexes.
    public static let mutation = NSRecursiveLock()

    public static func load(root: URL) -> VaultFile? {
        guard let d = try? Data(contentsOf: url(root: root)) else { return nil }
        return try? JSONDecoder().decode(VaultFile.self, from: d)
    }

    /// Fails closed: a vault file that exists but does not decode counts as enabled, so writes need
    /// the (unobtainable) key instead of silently going plain.
    public static func isEnabled(root: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url(root: root).path) else { return false }
        return load(root: root)?.enabled ?? true
    }

    static func save(_ v: VaultFile, root: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(enc.encode(v), to: url(root: root))
    }

    public static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.utf8)
        let status = salt.withUnsafeBytes { s in
            pw.withUnsafeBufferPointer { p in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                                     pw.count, s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw CryptoError.damaged("PBKDF2 failed: \(status)") }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: derived), salt: salt, info: info, outputByteCount: 32)
    }

    /// A new vault file (not yet written) and its key.
    static func make(password: String, iterations: Int) throws -> (VaultFile, SymmetricKey) {
        var salt = Data(count: 16)
        let rc = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard rc == errSecSuccess else { throw CryptoError.keychain(rc) }
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let verifier = try EncryptedFile.encrypt(verifierPlain, key: key)
        return (VaultFile(enabled: false, salt: salt, iterations: iterations, verifier: verifier), key)
    }

    /// The key for this root's vault, checked against the verifier. Also registers it for the store.
    @discardableResult
    public static func unlock(root: URL, password: String) throws -> SymmetricKey {
        guard let v = load(root: root) else {
            if FileManager.default.fileExists(atPath: url(root: root).path) { throw CryptoError.damaged("\(fileName) is unreadable") }
            throw CryptoError.notEncrypted
        }
        let key = try deriveKey(password: password, salt: v.salt, iterations: v.iterations)
        guard (try? EncryptedFile.decrypt(v.verifier, key: key)) == verifierPlain else { throw CryptoError.wrongPassword }
        TranscriptKeys.set(key, for: root)
        return key
    }

    /// Turns transcript encryption on: creates the vault when there is none (with `password`), checks
    /// the password otherwise, then encrypts every protected file in the root and reindexes.
    /// Returns the number of files encrypted.
    @discardableResult
    public static func lock(store: MeetingStore, password: String, iterations: Int = iterations) throws -> Int {
        mutation.lock(); defer { mutation.unlock() }
        var v: VaultFile
        let key: SymmetricKey
        if let existing = load(root: store.root) {
            key = try unlock(root: store.root, password: password)
            v = existing
        } else {
            (v, key) = try make(password: password, iterations: iterations)
            TranscriptKeys.set(key, for: store.root)
        }
        v.enabled = true
        try save(v, root: store.root)
        let n = try convert(store: store, key: key, encrypt: true)
        try IndexRenderer.reindex(store: store)
        return n
    }

    /// Turns transcript encryption off: decrypts every protected file in place. The vault file is
    /// kept (disabled) so `lock` with the same password resumes. Returns the number decrypted.
    @discardableResult
    public static func unlockAll(store: MeetingStore, password: String) throws -> Int {
        mutation.lock(); defer { mutation.unlock() }
        guard var v = load(root: store.root) else { return 0 }
        let key = try unlock(root: store.root, password: password)
        let n = try convert(store: store, key: key, encrypt: false)
        v.enabled = false
        try save(v, root: store.root)
        try IndexRenderer.reindex(store: store)
        return n
    }

    /// New salt and key; re-encrypts everything under the new key when enabled.
    public static func changePassword(store: MeetingStore, old: String, new: String, iterations: Int = iterations) throws {
        mutation.lock(); defer { mutation.unlock() }
        guard let current = load(root: store.root) else { throw CryptoError.notEncrypted }
        let oldKey = try unlock(root: store.root, password: old)
        var (v, newKey) = try make(password: new, iterations: iterations)
        v.enabled = current.enabled
        if current.enabled {
            // Decrypt to plain first so a crash midway leaves readable (plain) files, never a mix of keys.
            _ = try convert(store: store, key: oldKey, encrypt: false)
            try save(v, root: store.root)
            TranscriptKeys.set(newKey, for: store.root)
            _ = try convert(store: store, key: newKey, encrypt: true)
        } else {
            try save(v, root: store.root)
            TranscriptKeys.set(newKey, for: store.root)
        }
    }

    /// Writes one meeting's protected files, decrypted, plus `meeting.json` into `dir/<id>/`.
    @discardableResult
    public static func export(store: MeetingStore, id: String, to dir: URL) throws -> URL {
        _ = try store.loadMeeting(id)
        let out = dir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for name in [MeetingStore.meetingFile] + protectedFiles {
            if let d = try store.readData(id, name) { try AtomicFile.write(d, to: out.appendingPathComponent(name)) }
        }
        return out
    }

    static func convert(store: MeetingStore, key: SymmetricKey, encrypt: Bool) throws -> Int {
        let fm = FileManager.default
        var n = 0
        for id in store.listMeetingIDs() {
            let folder = store.folder(id)
            for name in protectedFiles {
                let plain = folder.appendingPathComponent(name)
                let sealed = folder.appendingPathComponent(name + "." + EncryptedFile.suffix)
                if encrypt, fm.fileExists(atPath: plain.path) {
                    try AtomicFile.write(EncryptedFile.encrypt(Data(contentsOf: plain), key: key), to: sealed)
                    try fm.removeItem(at: plain); n += 1
                } else if !encrypt, fm.fileExists(atPath: sealed.path) {
                    try AtomicFile.write(EncryptedFile.decrypt(Data(contentsOf: sealed), key: key), to: plain)
                    try fm.removeItem(at: sealed); n += 1
                }
            }
        }
        return n
    }
}

/// Unlocked transcript keys held in memory for this process, by root folder.
public enum TranscriptKeys {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var keys: [String: SymmetricKey] = [:]

    public static func set(_ key: SymmetricKey?, for root: URL) {
        lock.lock(); keys[root.standardizedFileURL.path] = key; lock.unlock()
    }

    public static func key(for root: URL) -> SymmetricKey? {
        lock.lock(); defer { lock.unlock() }; return keys[root.standardizedFileURL.path]
    }
}
