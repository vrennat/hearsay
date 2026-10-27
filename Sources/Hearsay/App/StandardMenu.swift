import AppKit
import HearsayCore
import SwiftUI

/// Which menu bar extra body Hearsay shows, read once at launch from `Prefs.menuStyle`.
/// `.panel` (default, Tanner's preference) is the rich window panel; `.menu` is the HIG's "display a menu, not a popover", kept for people who want a plain menu.
enum MenuStyle: String, CaseIterable {
    case menu, panel

    static var current: MenuStyle { Prefs.defaults.string(forKey: Prefs.menuStyle).flatMap(MenuStyle.init) ?? .panel }

    var title: String { self == .menu ? "Standard menu" : "Rich panel" }
}

/// One item of the standard menu. The SwiftUI menu body and the `--preview-menu` text dump are both
/// built from this list, so what the dump shows is what the NSMenu gets.
struct MenuEntry: Identifiable {
    enum Kind {
        case status                 // disabled text line
        case action(() -> Void)
        case submenu([MenuEntry])
        case divider
    }
    var id: String
    var title: String = ""
    var symbol: String? = nil
    var key: KeyEquivalent? = nil   // always with ⌘
    var enabled = true
    var help: String? = nil
    var kind: Kind

    static func divider(_ id: String) -> MenuEntry { MenuEntry(id: id, kind: .divider) }

    /// `Title [⌘K] (disabled) {on|off} <symbol>` per line, submenu items indented.
    func dump(indent: String = "") -> [String] {
        if case .divider = kind { return [indent + "---"] }
        var s = indent + title
        if let key { s += "  ⌘\(String(key.character).uppercased())" }
        if !enabled || { if case .status = kind { return true }; return false }() { s += "  (disabled)" }
        if let symbol { s += "  <\(symbol)>" }
        if case .submenu(let items) = kind { return [s + "  >"] + items.flatMap { $0.dump(indent: indent + "    ") } }
        return [s]
    }
}

@MainActor
enum StandardMenu {
    static func entries(model: AppModel, openSettings: @escaping () -> Void) -> [MenuEntry] {
        var e: [MenuEntry] = []
        let rec = MenuRecording.current(model)

        // Status, then the primary action.
        let status: String
        if let rec { status = "Recording \(MenuContent.elapsed(rec.elapsed))" }
        else if !model.queue.isIdle {
            let n = model.queue.busy.count
            status = "Transcribing \(n) \(n == 1 ? "meeting" : "meetings")"
        } else { status = "Ready" }
        e.append(MenuEntry(id: "status", title: status, symbol: rec != nil ? "record.circle.fill" : nil, kind: .status))
        if let rec {
            e.append(MenuEntry(id: "stop", title: "Stop Recording", symbol: "stop.fill", key: "r",
                               help: "Stop recording “\(rec.title)” and transcribe it", kind: .action { model.stop() }))
        } else {
            e.append(MenuEntry(id: "start", title: "Start Recording", symbol: "record.circle", key: "r",
                               help: CalendarService.shared.current.map { "Start recording “\($0.title)”" } ?? "Start recording a meeting",
                               kind: .action { model.start() }))
        }

        if let rec {
            let tapFailed = rec.warnings.contains { if case .tapFailed = $0 { return true }; return false }
            let micWarn = rec.warnings.contains { if case .tapFailed = $0 { return false }; return true }
            e.append(.divider("d-rec"))
            e.append(MenuEntry(id: "mic", title: micWarn ? "Mic: no audio" : (rec.micActive ? "Mic: hearing" : "Mic: quiet"),
                               symbol: micWarn ? "mic.slash" : "mic.fill", kind: .status))
            e.append(MenuEntry(id: "call", title: tapFailed ? "Call audio: failed" : (rec.callActive ? "Call audio: playing" : "Call audio: quiet"),
                               symbol: tapFailed ? "speaker.slash" : "speaker.wave.3.fill", kind: .status))
            for w in rec.warnings.map(\.text).sorted() {
                e.append(MenuEntry(id: "w-\(w)", title: w, symbol: "exclamationmark.triangle", kind: .status))
            }
            e.append(MenuEntry(id: "live", title: "Live Window…", symbol: "text.bubble",
                               help: "Show the transcript as it is spoken",
                               kind: .action { _ = LiveWindowController.shared.show() }))
        } else if let err = model.lastError {
            e.append(MenuEntry(id: "err", title: err, symbol: "exclamationmark.triangle", kind: .status))
        }

        if let ev = CalendarService.shared.current {
            e.append(.divider("d-cal"))
            let t = ev.title.isEmpty ? "Untitled event" : ev.title
            e.append(MenuEntry(id: "cal", title: "\(t), until \(ev.end.formatted(date: .omitted, time: .shortened))",
                               symbol: "calendar", help: rec == nil ? "Start Recording uses this title and its guest list" : nil,
                               kind: .status))
        }

        e.append(.divider("d-recent"))
        let recent: [MenuEntry] = model.recent.prefix(AppModel.recentLimit).map { m in
            let processing = model.queue.current == m.id, queued = model.queue.pending.contains(m.id)
            let word = MeetingStatusSymbol.word(m, processing: processing, queued: queued)
            return MenuEntry(id: "m-\(m.id)", title: m.title,
                             symbol: MeetingStatusSymbol.name(m, processing: processing, queued: queued),
                             help: "\(m.startedAt.formatted(.relative(presentation: .named))) · \(word)",
                             kind: .action { MeetingOpener.open(m) })
        }
        e.append(MenuEntry(id: "recent", title: "Recent Meetings", symbol: "clock",
                           kind: .submenu(recent.isEmpty ? [MenuEntry(id: "none", title: "No Meetings", kind: .status)] : recent)))
        e.append(MenuEntry(id: "folder", title: "Open Meetings Folder", symbol: "folder",
                           help: "Show \(model.store.root.path) in Finder",
                           kind: .action { NSWorkspace.shared.open(model.store.root) }))

        e.append(.divider("d-app"))
        e.append(MenuEntry(id: "open", title: "Open Hearsay", symbol: "macwindow", key: "o",
                           help: "Show every meeting in the Hearsay window",
                           kind: .action { MainWindowController.shared.show() }))
        e.append(MenuEntry(id: "settings", title: "Settings…", symbol: "gearshape", key: ",", kind: .action(openSettings)))
        if Updater.available {
            e.append(MenuEntry(id: "update", title: "Check for Updates…", symbol: "arrow.down.circle",
                               kind: .action { Updater.checkForUpdates() }))
        }
        e.append(MenuEntry(id: "help", title: "Help", symbol: "questionmark.circle",
                           kind: .action { NSWorkspace.shared.open(MenuContent.helpURL) }))
        e.append(.divider("d-quit"))
        e.append(MenuEntry(id: "quit", title: "Quit", key: "q",
                           help: model.isRecording ? "Stops the recording and transcribes it next launch" : nil,
                           kind: .action { NSApp.terminate(nil) }))
        return e
    }

    /// Prints the menu for `--preview-menu` with `--preview-menu-style menu`, since a status-item
    /// NSMenu cannot be rendered to an image without a menu bar and Screen Recording.
    static func dump(model: AppModel) -> String {
        model.refreshRecent()
        return entries(model: model, openSettings: {})
            .flatMap { $0.dump() }.joined(separator: "\n")
    }

    /// Relaunch: a detached shell waits for this process to exit, then opens the bundle again.
    static var canRestart: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func restart() {
        guard canRestart else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$0\"",
                       Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

/// The standard menu body for `.menuBarExtraStyle(.menu)`: plain buttons, a submenu and
/// disabled text, which SwiftUI turns into a real NSMenu (system highlight, VoiceOver, type-select).
struct StandardMenuContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let open = openSettings
        ForEach(StandardMenu.entries(model: model,
                                     openSettings: { MenuContent.showSettings(open) })) { item($0) }
            .onAppear { model.menuOpened() }
    }

    private func item(_ e: MenuEntry) -> AnyView {
        switch e.kind {
        case .divider:
            return AnyView(Divider())
        case .status:
            return AnyView(label(e).disabled(true))
        case .action(let run):
            return AnyView(shortcut(Button(action: run) { label(e) }, e.key).disabled(!e.enabled).help(e.help ?? ""))
        case .submenu(let items):
            return AnyView(Menu { ForEach(items) { item($0) } } label: { label(e) })
        }
    }

    @ViewBuilder private func label(_ e: MenuEntry) -> some View {
        if let s = e.symbol { Label(e.title, systemImage: s) } else { Text(e.title) }
    }

    @ViewBuilder private func shortcut(_ v: some View, _ key: KeyEquivalent?) -> some View {
        if let key { v.keyboardShortcut(key, modifiers: .command) } else { v }
    }
}
