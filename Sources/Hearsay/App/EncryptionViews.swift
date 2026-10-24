import AppKit
import HearsayCore
import SwiftUI

/// The transcript password prompt shown at launch while the Meetings folder's transcripts are
/// encrypted. The key is held in memory (`TranscriptKeys`) for the life of the process.
@MainActor
final class UnlockWindowController {
    static let shared = UnlockWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 170),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Unlock Transcripts"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: UnlockView { [weak self] in self?.close() })
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }
}

struct UnlockView: View {
    let done: () -> Void
    @State private var password = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        Form {
            Section {
                SecureField("Password", text: $password)
                    .onSubmit(unlock)
            } footer: {
                Text(error ?? "Your transcripts are encrypted. Recording works while locked; processing waits for the password.")
                    .foregroundStyle(error == nil ? Color.secondary : Color.orange)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Later", action: done).keyboardShortcut(.cancelAction)
                Button("Unlock", action: unlock).keyboardShortcut(.defaultAction).disabled(password.isEmpty || working)
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 380)
    }

    private func unlock() {
        guard !password.isEmpty, !working else { return }
        working = true
        let root = AppModel.shared.store.root, pw = password
        Task {
            // PBKDF2 at 600k iterations takes a fraction of a second; keep it off the main actor.
            let result: Error? = await Task.detached {
                do { try TranscriptVault.unlock(root: root, password: pw); return nil } catch { return error }
            }.value
            working = false
            if let result {
                error = String(describing: result)
            } else {
                AppModel.shared.transcriptsUnlocked()
                done()
            }
        }
    }
}

/// Settings → Storage: the two encryption toggles.
struct EncryptionSection: View {
    @AppStorage(Prefs.encryptRecordings, store: Prefs.defaults) private var encryptRecordings = true
    @State private var transcriptsOn = TranscriptVault.isEnabled(root: AppModel.shared.store.root)
    @State private var sheet: PasswordSheet.Mode?

    var body: some View {
        Section {
            Toggle(isOn: $encryptRecordings) {
                Text("Encrypt recordings")
                Text("Uses a key in your login Keychain.")
            }
            .help("Encrypted after transcription; if the Keychain item is lost, the audio cannot be played")
            .onChange(of: encryptRecordings) { _, on in AppModel.shared.setRecordingsEncrypted(on) }
            Toggle(isOn: Binding(get: { transcriptsOn }, set: { on in sheet = on ? .turnOn : .turnOff })) {
                Text("Encrypt transcripts with a password")
                Text("Agents need HEARSAY_PASSWORD to read them.")
            }
            .help("A lost password cannot be recovered")
            if transcriptsOn {
                Button("Change Password…") { sheet = .change }
            }
        } header: {
            Text("Encryption")
        } footer: {
            Text("Titles, dates and attendees stay readable so meetings can be found.")
        }
        .sheet(item: $sheet) { mode in
            PasswordSheet(mode: mode) { transcriptsOn = TranscriptVault.isEnabled(root: AppModel.shared.store.root); sheet = nil }
        }
    }
}

struct PasswordSheet: View {
    enum Mode: String, Identifiable { case turnOn, turnOff, change; var id: String { rawValue } }
    let mode: Mode
    let done: () -> Void
    @State private var current = ""
    @State private var new = ""
    @State private var confirm = ""
    @State private var error: String?
    @State private var working = false

    private var root: URL { AppModel.shared.store.root }
    private var hasVault: Bool { TranscriptVault.load(root: root) != nil }
    /// Turning on for the first time sets a password; turning on again reuses the old one.
    private var needsNew: Bool { mode == .change || (mode == .turnOn && !hasVault) }
    private var needsCurrent: Bool { mode != .turnOn || hasVault }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Form {
                if needsCurrent { SecureField("Current password", text: $current) }
                if needsNew {
                    SecureField("New password", text: $new)
                    SecureField("Type it again", text: $confirm)
                }
            }
            .formStyle(.grouped)
            if needsNew {
                Label("There is no way to recover this password. If you lose it, your transcripts are gone.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button(actionTitle, action: run).keyboardShortcut(.defaultAction).disabled(!valid || working)
            }
        }
        .padding()
        .frame(width: 420)
    }

    private var title: String {
        switch mode {
        case .turnOn: return "Encrypt Transcripts"
        case .turnOff: return "Decrypt Transcripts"
        case .change: return "Change Transcript Password"
        }
    }

    private var actionTitle: String {
        switch mode { case .turnOn: return "Encrypt"; case .turnOff: return "Decrypt"; case .change: return "Change" }
    }

    private var valid: Bool {
        (!needsCurrent || !current.isEmpty) && (!needsNew || (!new.isEmpty && new == confirm))
    }

    private func run() {
        working = true
        let store = AppModel.shared.store, mode = mode, current = current, new = new, needsNew = needsNew
        Task {
            let result: Error? = await Task.detached {
                do {
                    switch mode {
                    case .turnOn: try TranscriptVault.lock(store: store, password: needsNew ? new : current)
                    case .turnOff: try TranscriptVault.unlockAll(store: store, password: current)
                    case .change: try TranscriptVault.changePassword(store: store, old: current, new: new)
                    }
                    return nil
                } catch { return error }
            }.value
            working = false
            if let result { error = String(describing: result) } else { AppModel.shared.refreshRecent(); done() }
        }
    }
}
