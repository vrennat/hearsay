import CryptoKit
import Foundation

public enum StoreError: Error, CustomStringConvertible {
    case meetingNotFound(String)
    public var description: String {
        switch self { case .meetingNotFound(let id): return "No meeting folder named \(id)" }
    }
}

/// File store over a root folder (default `~/Meetings`). The root is never persisted.
public struct MeetingStore: Sendable {
    public static let meetingFile = "meeting.json"
    public static let transcriptFile = "transcript.json"
    public static let cleanupFile = "cleanup.json"
    public static let liveJSONFile = "live.json"
    public static let liveMarkdownFile = "live.md"

    public let root: URL
    private static let log = HearsayCore.logger("store")

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Meetings", isDirectory: true)
    }

    public init(root: URL? = nil) {
        self.root = (root ?? Self.defaultRoot).standardizedFileURL
    }

    /// Creates the root and seeds `CLAUDE.md` and `glossary.txt` only when they are missing.
    public func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try seed("CLAUDE.md", SeedFiles.readingGuide)
        try seed(Glossary.fileName, SeedFiles.glossary)
    }

    private func seed(_ name: String, _ contents: String) throws {
        let url = root.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try AtomicFile.write(contents, to: url)
    }

    // MARK: Folders

    public func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    /// Folder name `yyyy-MM-dd HHmm <slug>`, suffixed `-2`, `-3` if taken. The folder name is the meeting id.
    public func newMeetingID(startedAt: Date, title: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        let slug = Self.slug(title)
        let base = slug.isEmpty ? f.string(from: startedAt) : "\(f.string(from: startedAt)) \(slug)"
        var id = base
        var n = 2
        while FileManager.default.fileExists(atPath: folder(id).path) { id = "\(base)-\(n)"; n += 1 }
        return id
    }

    static func slug(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -"))
        let cleaned = String(title.unicodeScalars.filter { allowed.contains($0) })
        let words = cleaned.split(separator: " ").prefix(8).joined(separator: " ")
        return String(words.prefix(60)).trimmingCharacters(in: .whitespaces)
    }

    public func listMeetingIDs() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(Self.meetingFile).path) }
            .map(\.lastPathComponent).sorted()
    }

    /// All readable meetings; unreadable folders are logged and skipped.
    public func loadAllMeetings() -> [Meeting] {
        listMeetingIDs().compactMap { id in
            do { return try loadMeeting(id) } catch {
                Self.log.error("Skipping \(id, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
        }
    }

    // MARK: JSON files

    public func loadMeeting(_ id: String) throws -> Meeting {
        guard var m: Meeting = try read(id, Self.meetingFile) else { throw StoreError.meetingNotFound(id) }
        m.id = id  // the folder name is the id
        return m
    }

    public func saveMeeting(_ meeting: Meeting) throws { try write(meeting, meeting.id, Self.meetingFile) }

    public func loadTranscript(_ id: String) throws -> Transcript? { try read(id, Self.transcriptFile) }
    public func saveTranscript(_ t: Transcript, id: String) throws { try write(t, id, Self.transcriptFile) }

    public func loadCleanup(_ id: String) throws -> Cleanup? { try read(id, Self.cleanupFile) }
    public func saveCleanup(_ c: Cleanup, id: String) throws { try write(c, id, Self.cleanupFile) }

    public func loadLive(_ id: String) throws -> LiveTranscript? { try read(id, Self.liveJSONFile) }

    /// Writes `live.json` and `live.md`. Never touches `meeting.json`.
    public func saveLive(_ live: LiveTranscript, id: String) throws {
        // Locked transcripts: the live view keeps its lines in memory; nothing is written until unlock.
        if transcriptsEncrypted, transcriptKey == nil { return }
        try write(live, id, Self.liveJSONFile)
        try writeText(LiveRenderer.markdown(live), id: id, name: Self.liveMarkdownFile)
    }

    // MARK: The one read/write seam (transcript encryption)

    /// Transcripts are stored as `.enc` (vault enabled in this root).
    public var transcriptsEncrypted: Bool { TranscriptVault.isEnabled(root: root) }

    /// The unlocked transcript key for this root, if the user has entered the password.
    public var transcriptKey: SymmetricKey? { TranscriptKeys.key(for: root) }

    /// A meeting file's bytes, decrypting `<name>.enc` when that is what exists. Nil when neither
    /// exists. Old plain files stay readable whatever the setting.
    public func readData(_ id: String, _ name: String) throws -> Data? {
        let plain = folder(id).appendingPathComponent(name)
        let sealed = folder(id).appendingPathComponent(name + "." + EncryptedFile.suffix)
        let fm = FileManager.default
        let order = transcriptsEncrypted ? [sealed, plain] : [plain, sealed]
        for url in order where fm.fileExists(atPath: url.path) {
            guard EncryptedFile.isEncrypted(url) else { return try Data(contentsOf: url) }
            guard let key = transcriptKey else { throw CryptoError.transcriptsLocked }
            return try EncryptedFile.decrypt(Data(contentsOf: url), key: key)
        }
        return nil
    }

    /// Writes a meeting file, as `<name>.enc` for the protected files while the vault is enabled
    /// (removing the other form, so exactly one exists).
    public func writeData(_ data: Data, id: String, name: String) throws {
        let plain = folder(id).appendingPathComponent(name)
        let sealed = folder(id).appendingPathComponent(name + "." + EncryptedFile.suffix)
        TranscriptVault.mutation.lock(); defer { TranscriptVault.mutation.unlock() }
        if transcriptsEncrypted, TranscriptVault.protectedFiles.contains(name) {
            guard let key = transcriptKey else { throw CryptoError.transcriptsLocked }
            try AtomicFile.write(EncryptedFile.encrypt(data, key: key), to: sealed)
            try? FileManager.default.removeItem(at: plain)
        } else {
            try AtomicFile.write(data, to: plain)
            // Only drop the `.enc` copy when it was readable to us; without a key (vault file missing)
            // keep it rather than lose the only copy of older text.
            if TranscriptVault.protectedFiles.contains(name), transcriptKey != nil { try? FileManager.default.removeItem(at: sealed) }
        }
    }

    public func readText(_ id: String, _ name: String) throws -> String? {
        try readData(id, name).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Whether `<name>` or `<name>.enc` exists.
    public func hasFile(_ id: String, _ name: String) -> Bool {
        let u = folder(id).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path)
            || FileManager.default.fileExists(atPath: u.path + "." + EncryptedFile.suffix)
    }

    private func read<T: Decodable>(_ id: String, _ name: String) throws -> T? {
        guard let data = try readData(id, name) else { return nil }
        return try JSONCoding.decoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, _ id: String, _ name: String) throws {
        try writeData(JSONCoding.encoder().encode(value), id: id, name: name)
    }

    public func writeText(_ text: String, id: String, name: String) throws {
        try writeData(Data(text.utf8), id: id, name: name)
    }
}
