import AppKit
import ApplicationServices
import Combine
import HearsayCore
import ServiceManagement
import SwiftUI

/// Settings, one tab per group (spec amendment "Apple Human Interface Guidelines"): General,
/// Recording, Storage, Dictation, Agents. Each pane is a grouped `Form` with `LabeledContent` rows and
/// explanations in section footers. All keys live in `Prefs.defaults` (`com.tannervass.hearsay`).
struct SettingsView: View {
    enum Tab: Hashable { case general, recording, storage, dictation, agents }
    @State private var tab: Tab

    init(initial: Tab = .general) { _tab = State(initialValue: initial) }

    var body: some View {
        TabView(selection: $tab) {
            GeneralPane()
                .tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            RecordingPane()
                .tabItem { Label("Recording", systemImage: "record.circle") }.tag(Tab.recording)
            StoragePane()
                .tabItem { Label("Storage", systemImage: "internaldrive") }.tag(Tab.storage)
            DictationPane()
                .tabItem { Label("Dictation", systemImage: "mic.badge.plus") }.tag(Tab.dictation)
            AgentsPane()
                .tabItem { Label("Agents", systemImage: "terminal") }.tag(Tab.agents)
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    /// Sizes a pane's grouped `Form` to its content so the Settings window fits each tab and never scrolls.
    func settingsPane() -> some View {
        formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
    }
}

/// The menu bar style this process launched with (`HearsayApp` reads `MenuStyle.current` once at
/// launch; this is read when Settings first draws, before the picker can change the saved value).
enum RunningMenuStyle { static let value = MenuStyle.current }

/// A footer in the standard secondary style.
struct FormFooter: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct GeneralPane: View {
    @AppStorage(Prefs.userName, store: Prefs.defaults) private var userName = ""
    @AppStorage(Prefs.menuStyle, store: Prefs.defaults) private var menuStyle = MenuStyle.panel.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var autoUpdate = false
    private var model: AppModel { AppModel.shared }

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $userName, prompt: Text("First Last"))
                    .help("Used to recognise your voice when the calendar invite does not say which attendee you are")
            } footer: {
                FormFooter("Helps recognise your voice in meetings.")
            }

            Section {
                Picker("Menu bar style", selection: $menuStyle) {
                    ForEach([MenuStyle.panel, .menu], id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .help("The rich panel with control tiles, or a standard menu for macOS compatibility")
                if menuStyle != RunningMenuStyle.value.rawValue {
                    LabeledContent("Takes effect after Hearsay restarts") {
                        Button("Restart Hearsay") { StandardMenu.restart() }
                            .disabled(!StandardMenu.canRestart)
                            .help(StandardMenu.canRestart ? "Quit and reopen Hearsay" : "Only available in the app bundle")
                    }
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLoginItem(on) }
                    .help("Start Hearsay in the menu bar when you log in")
            } footer: {
                if let loginError {
                    Label(loginError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }

            Section {
                LabeledContent {
                    Button("Change…") { model.chooseMeetingsFolder() }
                        .disabled(!model.canChangeMeetingsFolder)
                        .help(model.meetingsFolderBlocked ?? "Choose where meetings are saved")
                } label: {
                    Text("Meetings folder")
                    PathCaption(path: model.store.root.path)
                }
                .accessibilityElement(children: .contain)
            } footer: {
                if model.options.root != nil {
                    FormFooter("This run uses --root; the saved folder is not changed.")
                } else if let why = model.meetingsFolderBlocked {
                    FormFooter(why)
                } else {
                    FormFooter("Each meeting is a folder of plain audio, JSON and Markdown files.")
                }
            }
            Section {
                LabeledContent("Version", value: HearsayCore.version)
                    .help("Hearsay \(HearsayCore.version)")
                if Updater.isRunning {
                    // Read Sparkle's own value each time: its first-run prompt can change it while this is open.
                    Toggle(isOn: Binding(get: { _ = autoUpdate; return Updater.automaticallyChecks },
                                         set: { Updater.automaticallyChecks = $0; autoUpdate = $0 })) {
                        Text("Check for updates automatically")
                        Text("Once a day; you are asked before anything installs.")
                    }
                    .onAppear { autoUpdate = Updater.automaticallyChecks }
                    LabeledContent("Updates") {
                        Button("Check Now") { Updater.checkForUpdates() }
                    }
                }
            }
        }
        .settingsPane()
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Could not change the login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct RecordingPane: View {
    @AppStorage(Prefs.cleanup, store: Prefs.defaults) private var cleanup = true
    @AppStorage(Prefs.notchPill, store: Prefs.defaults) private var notchPill = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $notchPill) {
                    Text("Show the timer while recording")
                    Text("Elapsed time and a level meter at the top of the screen, from the next recording.")
                }
                .help("Elapsed time and a level meter at the top of the screen, beside the notch on Macs that have one")
                Toggle(isOn: $cleanup) {
                    Text("Clean up transcripts")
                    Text("Removes fillers and repeated words; transcript.raw.md keeps the original.")
                }
                .help("Remove fillers and repeated words")
            }
            Section {
                Text(Consent.reminder)
            } header: {
                Text("Consent")
            } footer: {
                FormFooter(Consent.detail)
            }
            Section {
                LabeledContent("While recording") {
                    Text(Distribution.current == .appStore ? "Keeps the Mac awake" : "Keeps the Mac awake, lid closed too")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Sleep")
            } footer: {
                FormFooter(Distribution.current == .appStore
                    ? "The Mac can still sleep when the lid closes."
                    : "Lid-close sleep is restored when recording stops.")
            }
        }
        .settingsPane()
    }
}

/// Retention, and the place the encryption settings extend (spec amendment "Encryption at rest"):
/// add their sections after `retention`.
struct StoragePane: View {
    @AppStorage(Prefs.keepAudioDays, store: Prefs.defaults) private var keepAudioDays = Prefs.defaultKeepAudioDays
    @AppStorage(Prefs.keepTranscriptDays, store: Prefs.defaults) private var keepTranscriptDays = Prefs.defaultKeepTranscriptDays

    var body: some View {
        Form {
            retention
            EncryptionSection()
        }
        .settingsPane()
    }

    private var retention: some View {
        Section {
            Picker("Keep audio", selection: $keepAudioDays) {
                ForEach(Self.choices(including: keepAudioDays), id: \.self) { Text(Self.days($0)).tag($0) }
            }
            .help("Audio is deleted once the meeting is transcribed, or this long after it when kept")
            Picker("Keep transcripts", selection: $keepTranscriptDays) {
                ForEach(Self.choices(including: keepTranscriptDays, audio: false), id: \.self) { Text(Self.days($0)).tag($0) }
            }
            .help("Whole meeting folders go to the Trash after this long; checked at launch and every 24 hours")
        } header: {
            Text("Retention")
        } footer: {
            FormFooter("Audio is deleted as soon as the meeting is transcribed unless you choose to keep it. Old meetings go to the Trash.")
        }
    }

    static let presets = [1, 7, 30, 90, 365, 0]

    /// The presets, plus a value set elsewhere (the CLI or an older build) so the picker never goes blank.
    /// "Until transcribed" only makes sense for audio; a transcript is what transcription produces.
    static func choices(including n: Int, audio: Bool = true) -> [Int] {
        let base = presets.contains(n) ? presets : (presets.dropLast() + [n]).sorted() + [0]
        return audio ? [RetentionPlan.untilTranscribed] + base : base
    }

    static func days(_ n: Int) -> String {
        switch n {
        case RetentionPlan.untilTranscribed: "Until transcribed"
        case 0: "Forever"
        case 1: "24 hours"
        case 7: "1 week"
        case 30: "30 days"
        case 365: "1 year"
        default: "\(n) days"
        }
    }
}

/// Two things an agent needs: the `hearsay` command and the Meetings folder. When the command is
/// installed the row says only that; the install action appears only when it is not. The Developer ID
/// build creates the `~/.local/bin/hearsay` symlink itself; the App Store sandbox cannot write there,
/// so it shows the command to paste into Terminal.
struct AgentsPane: View {
    @State private var state = CLIInstall.state()
    @State private var copied: String?
    @State private var error: String?
    private var model: AppModel { AppModel.shared }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack {
                        Text(state.title).foregroundStyle(.secondary)
                        if state != .installed, Distribution.current != .appStore {
                            Button(state == .other ? "Replace" : "Install") {
                                do { try CLIInstall.install(); error = nil } catch { self.error = "Could not install: \(error.localizedDescription)" }
                                state = CLIInstall.state()
                            }
                            .help("Link hearsay into ~/.local/bin")
                        }
                    }
                } label: {
                    Text("hearsay command")
                    Text(state == .installed ? "Run hearsay --help in Terminal" : "Puts hearsay on your PATH")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if state != .installed, Distribution.current == .appStore {
                    HStack(alignment: .top) {
                        Text(CLIInstall.linkCommand).font(.caption.monospaced()).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        copyButton("Copy", CLIInstall.linkCommand, help: "Copy the command to paste into Terminal")
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } header: {
                Text("Command line")
            } footer: {
                FormFooter("Lists, transcribes and renames meetings from a script or an agent.")
            }
            Section {
                LabeledContent {
                    copyButton("Copy Path", model.store.root.path, help: "Copy the Meetings folder path")
                } label: {
                    Text("Meetings folder")
                    PathCaption(path: model.store.root.path)
                }
            } header: {
                Text("For agents")
            } footer: {
                FormFooter("Each meeting is a folder with transcript.md to read and meeting.json for details. Point an agent at this folder or at the hearsay command.")
            }
        }
        .settingsPane()
    }

    private func copyButton(_ title: String, _ text: String, help: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = title
        } label: {
            Label(copied == title ? "Copied" : title, systemImage: copied == title ? "checkmark" : "doc.on.doc")
        }
        .help(help)
    }
}

enum CLIInstall {
    enum State { case installed, other, missing
        var title: String {
            switch self {
            case .installed: "Installed"
            case .other: "Another hearsay is in ~/.local/bin"
            case .missing: "Not installed"
            }
        }
    }

    static var cliPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/hearsay-cli").path }
    static var linkCommand: String { "mkdir -p ~/.local/bin && ln -sf '\(cliPath)' ~/.local/bin/hearsay" }
    static var link: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/hearsay") }

    /// A symlink to this bundle's CLI, or a regular file (`build-app.sh` copies one), counts as installed.
    static func state() -> State {
        let fm = FileManager.default
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            return URL(fileURLWithPath: dest, relativeTo: link.deletingLastPathComponent()).standardizedFileURL.path
                == URL(fileURLWithPath: cliPath).standardizedFileURL.path ? .installed : .other
        }
        return fm.fileExists(atPath: link.path) ? .installed : .missing
    }

    /// Replaces only a symlink; a regular file reads as installed and is never deleted here.
    static func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil { try fm.removeItem(at: link) }
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: cliPath)
    }
}

/// A path under a row's label: secondary caption, home shown as `~`, one line, middle truncation,
/// selectable (the tooltip and the copy buttons keep the full path).
struct PathCaption: View {
    let path: String
    var body: some View {
        Text((path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(path)
    }
}

struct DictationPane: View {
    @AppStorage(Prefs.dictation, store: Prefs.defaults) private var enabled = false
    @AppStorage(Prefs.dictationKey, store: Prefs.defaults) private var key = DictationKey.rightOption.rawValue
    @State private var trusted = AXIsProcessTrusted()
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Dictate anywhere by holding a key", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in DictationController.shared.settingsChanged() }
                    .disabled(AppModel.shared.options.isTestInstance)
                Picker(selection: $key) {
                    ForEach(DictationKey.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                } label: {
                    Text("Key")
                    Text("A quick tap keeps listening until the next press; Esc cancels.")
                }
                .onChange(of: key) { _, _ in DictationController.shared.settingsChanged() }
                .disabled(!enabled)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    FormFooter("Hold the key and talk; release to paste.")
                    if AppModel.shared.options.isTestInstance {
                        Label("Dictation is off in test instances (--root, --record-for).", systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                LabeledContent {
                    HStack {
                        Label(trusted ? "Allowed" : "Not allowed",
                              systemImage: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(trusted ? .green : .orange)
                        Button("Open Settings…") { DictationController.openAccessibilitySettings() }
                            .help("Open Privacy & Security > Accessibility in System Settings")
                    }
                } label: {
                    Text("Accessibility")
                    Text(trusted ? "Hearsay can paste into the focused app."
                                 : "Without it, text stays on the clipboard.")
                }
            }
        }
        .settingsPane()
        .onReceive(poll) { _ in trusted = AXIsProcessTrusted() }
    }
}
