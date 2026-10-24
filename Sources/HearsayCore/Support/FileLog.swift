import Foundation
import os

/// Appends timestamped lines to `~/Library/Logs/Hearsay.log` (the app and the CLI share it).
/// `os.Logger` is for Console; this file is what survives to be read after a crash.
public final class FileLog: @unchecked Sendable {
    /// Test runs write to a temp file so `swift test` never fills the real log.
    public static let shared = FileLog(url: isTestProcess
        ? FileManager.default.temporaryDirectory.appendingPathComponent("Hearsay-tests.log") : defaultURL)

    static var isTestProcess: Bool {
        let name = ProcessInfo.processInfo.processName.lowercased()
        return name.contains("xctest") || name.contains("swiftpm-testing-helper") || name.hasSuffix("packagetests")
    }
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Hearsay.log")
    }

    public let url: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(url: URL) { self.url = url }

    public func write(_ category: String, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) [\(ProcessInfo.processInfo.processIdentifier)] [\(category)] \(message)\n"
        if handle == nil {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
        }
        _ = try? handle?.seekToEnd()  // another process (CLI, test instance) may have appended
        try? handle?.write(contentsOf: Data(line.utf8))
    }
}

/// Logs each line to `os.Logger` (subsystem `com.tannervass.hearsay`) and to `FileLog`.
public struct HSLog: Sendable {
    public let category: String
    private let logger: Logger
    private let file: FileLog

    public init(_ category: String, file: FileLog = .shared) {
        self.category = category
        self.logger = Logger(subsystem: HearsayCore.subsystem, category: category)
        self.file = file
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        file.write(category, message)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        file.write(category, "ERROR " + message)
    }
}
