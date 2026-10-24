import CryptoKit
import Foundation
import Security

/// Where the recordings key lives. Injectable so tests never touch the login Keychain.
public protocol AudioKeyStore: Sendable {
    func load() throws -> SymmetricKey?
    func save(_ key: SymmetricKey) throws
}

/// The login Keychain item `com.tannervass.hearsay` / `recordings-key`, this device only.
///
/// A login-keychain item carries a partition list set from the binary that created it: a team-signed
/// binary gets `teamid:…`, which every other binary signed by the team reads without a prompt, while an
/// ad-hoc debug binary gets its own code hash, which prompts everyone else. The original `audio-key`
/// item was made by a debug `hearsay-cli` and every signed app build prompted (2026-10-24), so the key
/// moved to `recordings-key`, created fresh by the signed app. Nothing reads `audio-key` any more
/// (Tanner, 2026-10-24: treat it as brand new). `keychain-access-groups` would be cleaner but
/// Developer ID apps cannot carry it without a profile.
/// `HEARSAY_KEYCHAIN_SERVICE` overrides the service name (scratch end-to-end runs only).
public struct KeychainAudioKeyStore: AudioKeyStore {
    public let service: String
    public let account: String

    public init(service: String = ProcessInfo.processInfo.environment["HEARSAY_KEYCHAIN_SERVICE"] ?? "com.tannervass.hearsay",
                account: String = "recordings-key") {
        self.service = service; self.account = account
    }

    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() throws -> SymmetricKey? { try read(account: account) }

    public func save(_ key: SymmetricKey) throws { try add(key) }

    private func read(account: String) throws -> SymmetricKey? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw CryptoError.keychain(status) }
        guard data.count == 32 else { throw CryptoError.damaged("Keychain audio key is \(data.count) bytes") }
        return SymmetricKey(data: data)
    }

    private func add(_ key: SymmetricKey) throws {
        var q = query(account: account)
        q[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        q[kSecAttrLabel as String] = "Hearsay recordings key"
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw CryptoError.keychain(status) }
    }
}

/// Test store.
public final class InMemoryAudioKeyStore: AudioKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    public init(key: SymmetricKey? = nil) { self.key = key }
    public func load() throws -> SymmetricKey? { lock.lock(); defer { lock.unlock() }; return key }
    public func save(_ key: SymmetricKey) throws { lock.lock(); self.key = key; lock.unlock() }
}

/// The recordings key for this process.
public enum AudioKey {
    private static let lock = NSLock()
    /// Test processes never touch the login Keychain.
    nonisolated(unsafe) private static var _store: any AudioKeyStore =
        FileLog.isTestProcess ? InMemoryAudioKeyStore() : KeychainAudioKeyStore()
    nonisolated(unsafe) private static var cached: SymmetricKey?

    public static var store: any AudioKeyStore {
        get { lock.lock(); defer { lock.unlock() }; return _store }
        set { lock.lock(); _store = newValue; cached = nil; lock.unlock() }
    }

    /// For reading: throws `audioKeyMissing` when the item is gone, never creates one.
    public static func existing() throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        guard let k = try _store.load() else { throw CryptoError.audioKeyMissing }
        cached = k
        return k
    }

    /// For writing: creates the random 256-bit key on first use.
    public static func getOrCreate() throws -> SymmetricKey {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        if let k = try _store.load() { cached = k; return k }
        let k = SymmetricKey(size: .bits256)
        try _store.save(k)
        cached = k
        return k
    }
}
