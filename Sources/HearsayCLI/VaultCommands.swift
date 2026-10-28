import ArgumentParser
import Darwin
import Foundation
import HearsayCore

/// `HEARSAY_PASSWORD`, else a no-echo prompt when stdin is a terminal, else nil.
enum Password {
    static func get(prompt: String) -> String? {
        if let env = ProcessInfo.processInfo.environment["HEARSAY_PASSWORD"], !env.isEmpty { return env }
        guard isatty(STDIN_FILENO) == 1, let p = getpass(prompt) else { return nil }
        let s = String(cString: p)
        return s.isEmpty ? nil : s
    }

    static func required(prompt: String) throws -> String {
        guard let p = get(prompt: prompt) else { throw ValidationError("Set HEARSAY_PASSWORD or run in a terminal to enter the password") }
        return p
    }

    /// A new password: twice on a terminal; the env var counts as confirmed.
    static func new() throws -> String {
        let first = try required(prompt: "New transcript password (unrecoverable if lost): ")
        if ProcessInfo.processInfo.environment["HEARSAY_PASSWORD"]?.isEmpty == false { return first }
        guard try required(prompt: "Type it again: ") == first else { throw ValidationError("The passwords differ") }
        return first
    }
}

struct LockCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lock",
        abstract: "Encrypt every transcript and its Markdown with the password (creates it on first use; unrecoverable).")
    @OptionGroup var root: RootOption

    mutating func run() throws {
        let store = root.plainStore
        let pw = TranscriptVault.load(root: store.root) == nil ? try Password.new() : try Password.required(prompt: "Transcript password: ")
        let n = try TranscriptVault.lock(store: store, password: pw)
        print("Locked: \(n) file(s) encrypted in \(store.root.path)")
    }
}

struct UnlockCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unlock", abstract: "Decrypt every transcript in place and turn transcript encryption off.")
    @OptionGroup var root: RootOption

    mutating func run() throws {
        let store = root.plainStore
        guard TranscriptVault.load(root: store.root) != nil else { print("Not locked: \(store.root.path)"); return }
        let n = try TranscriptVault.unlockAll(store: store, password: try Password.required(prompt: "Transcript password: "))
        print("Unlocked: \(n) file(s) decrypted in \(store.root.path)")
    }
}

struct ExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export", abstract: "Write one meeting's transcripts (and with --audio its recordings), decrypted, to a folder.")
    @Argument(help: "Meeting id (folder name).") var id: String
    @Option(help: "Destination folder (default: the current folder).") var to: String = "."
    @Flag(help: "Also write the audio streams, decrypted, to <folder>/<id>/audio/ (for sharing a meeting to debug it).") var audio = false
    @OptionGroup var root: RootOption

    mutating func run() throws {
        let dir = URL(fileURLWithPath: (to as NSString).expandingTildeInPath, isDirectory: true)
        let out = try TranscriptVault.export(store: root.store, id: id, to: dir)
        if audio {
            for f in try AudioVault.export(id, store: root.store, to: out.appendingPathComponent("audio", isDirectory: true)) { print(f.path) }
        }
        print(out.path)
    }
}
