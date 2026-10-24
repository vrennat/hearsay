import CryptoKit
import Foundation

public enum CryptoError: Error, CustomStringConvertible, Equatable {
    case notEncrypted
    case damaged(String)
    case audioKeyMissing
    case transcriptsLocked
    case wrongPassword
    case keychain(OSStatus)

    public var description: String {
        switch self {
        case .notEncrypted: return "Not a Hearsay encrypted file (no HSE1 header)"
        case .damaged(let why): return "Encrypted file is damaged or was changed: \(why)"
        case .audioKeyMissing:
            return "The recording key is missing from the login Keychain (com.tannervass.hearsay / audio-key); encrypted audio cannot be read"
        case .transcriptsLocked:
            return "Transcripts are encrypted; unlock them with the password (set HEARSAY_PASSWORD for the CLI)"
        case .wrongPassword: return "Wrong password"
        case .keychain(let status): return "Keychain error \(status)"
        }
    }
}

/// The `.enc` format: `HSE1`, a 12-byte base nonce, then chunks of up to 1 MiB plaintext, each
/// stored as AES-GCM ciphertext plus its 16-byte tag. Chunk i's nonce is the base nonce with i
/// XORed into its last 8 bytes (big endian). Each chunk authenticates `index || final` as associated
/// data, so reordering, dropping or truncating chunks fails to decrypt. Empty plaintext is one empty
/// final chunk.
public enum EncryptedFile {
    public static let magic = Data("HSE1".utf8)
    public static let suffix = "enc"
    public static let chunkSize = 1 << 20
    static let nonceSize = 12
    static let tagSize = 16
    static var headerSize: Int { magic.count + nonceSize }

    public static func isEncrypted(_ url: URL) -> Bool { url.pathExtension == suffix }

    // MARK: In memory

    public static func encrypt(_ plain: Data, key: SymmetricKey) throws -> Data {
        var out = Data()
        var offset = 0
        try encrypt(key: key, read: { n in
            let end = min(plain.count, offset + n)
            defer { offset = end }
            return plain.subdata(in: (plain.startIndex + offset)..<(plain.startIndex + end))
        }, write: { out.append($0) })
        return out
    }

    public static func decrypt(_ sealed: Data, key: SymmetricKey) throws -> Data {
        var out = Data()
        var offset = 0
        try decrypt(key: key, read: { n in
            let end = min(sealed.count, offset + n)
            defer { offset = end }
            return sealed.subdata(in: (sealed.startIndex + offset)..<(sealed.startIndex + end))
        }, write: { out.append($0) })
        return out
    }

    // MARK: Files (streaming; at most two chunks in memory)

    /// Encrypts `source` into `destination` through a temp file in the destination's folder.
    public static func encryptFile(_ source: URL, to destination: URL, key: SymmetricKey) throws {
        try stream(source, destination) { r, w in try encrypt(key: key, read: r, write: w) }
    }

    public static func decryptFile(_ source: URL, to destination: URL, key: SymmetricKey) throws {
        try stream(source, destination) { r, w in try decrypt(key: key, read: r, write: w) }
    }

    /// Whole-file decrypt into memory (compressed audio, transcripts).
    public static func decryptFile(_ source: URL, key: SymmetricKey) throws -> Data {
        let h = try FileHandle(forReadingFrom: source)
        defer { try? h.close() }
        var out = Data()
        try decrypt(key: key, read: { try h.read(upToCount: $0) ?? Data() }, write: { out.append($0) })
        return out
    }

    private static func stream(_ source: URL, _ destination: URL,
                               _ body: (_ read: (Int) throws -> Data, _ write: (Data) throws -> Void) throws -> Void) throws {
        let fm = FileManager.default
        let dir = destination.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path])
        }
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: tmp)
            defer { try? output.close() }
            try body({ try input.read(upToCount: $0) ?? Data() }, { try output.write(contentsOf: $0) })
            try output.synchronize()
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: destination)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    // MARK: Core

    /// `read(n)` returns up to n bytes, empty at the end.
    static func encrypt(key: SymmetricKey, chunk: Int = chunkSize, read: (Int) throws -> Data, write: (Data) throws -> Void) throws {
        let base = Data(AES.GCM.Nonce())
        try write(magic + base)
        var index: UInt64 = 0
        var current = try readFull(chunk, read)
        while true {
            let next = current.count == chunk ? try readFull(chunk, read) : Data()
            let final = next.isEmpty
            let box = try AES.GCM.seal(current, using: key, nonce: nonce(base, index), authenticating: aad(index, final))
            try write(box.ciphertext + box.tag)
            if final { return }
            current = next
            index += 1
        }
    }

    static func decrypt(key: SymmetricKey, chunk: Int = chunkSize, read: (Int) throws -> Data, write: (Data) throws -> Void) throws {
        let header = try readFull(headerSize, read)
        guard header.count == headerSize, header.prefix(magic.count) == magic else { throw CryptoError.notEncrypted }
        let base = header.suffix(nonceSize)
        let sealedChunk = chunk + tagSize
        var index: UInt64 = 0
        var current = try readFull(sealedChunk, read)
        while true {
            guard current.count >= tagSize else { throw CryptoError.damaged("truncated chunk \(index)") }
            let next = current.count == sealedChunk ? try readFull(sealedChunk, read) : Data()
            let final = next.isEmpty
            let ct = current.prefix(current.count - tagSize)
            let tag = current.suffix(tagSize)
            do {
                let box = try AES.GCM.SealedBox(nonce: nonce(Data(base), index), ciphertext: ct, tag: tag)
                try write(try AES.GCM.open(box, using: key, authenticating: aad(index, final)))
            } catch {
                throw CryptoError.damaged("chunk \(index) failed authentication (wrong key, changed or truncated)")
            }
            if final {
                guard try read(1).isEmpty else { throw CryptoError.damaged("bytes after the final chunk") }
                return
            }
            current = next
            index += 1
        }
    }

    private static func readFull(_ n: Int, _ read: (Int) throws -> Data) throws -> Data {
        var out = Data()
        while out.count < n {
            let d = try read(n - out.count)
            if d.isEmpty { break }
            out.append(d)
        }
        return out
    }

    static func nonce(_ base: Data, _ index: UInt64) throws -> AES.GCM.Nonce {
        var bytes = [UInt8](base)
        for i in 0..<8 { bytes[nonceSize - 1 - i] ^= UInt8((index >> (8 * UInt64(i))) & 0xff) }
        return try AES.GCM.Nonce(data: bytes)
    }

    static func aad(_ index: UInt64, _ final: Bool) -> Data {
        var d = Data(magic)
        withUnsafeBytes(of: index.bigEndian) { d.append(contentsOf: $0) }
        d.append(final ? 1 : 0)
        return d
    }
}
