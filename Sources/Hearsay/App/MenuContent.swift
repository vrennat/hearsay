import AppKit
import HearsayCore
import SwiftUI

/// The menu bar extra's panel, laid out like a first-party menu bar app (spec amendment "Apple Human
/// Interface Guidelines"): a header with name and state; the primary action as a prominent
/// button; a grid of labelled control tiles with a details card for the hovered or focused one; the
/// calendar line; recent meetings with their status; then the app rows. Standard controls, system
/// colours and fonts only; the panel's own background is the system menu material.
///
/// The panel never squishes: the details card reserves a title line plus two description lines
/// whatever the hovered tile says, recent rows have a fixed height, and the stack is `fixedSize`
/// vertically, so the `MenuBarExtra` window sizes to the content instead of compressing it.
struct MenuContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    /// Nil until the pointer reaches a tile: no tile looks chosen when the panel opens.
    @State private var selected: MenuControl?

    init(model: AppModel, selected: MenuControl? = nil) {
        self.model = model
        _selected = State(initialValue: selected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuHeader(model: model)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            PrimaryAction(model: model, recording: MenuRecording.current(model))
                .padding(.horizontal, 14).padding(.bottom, 10)
            warnings
            Divider().padding(.horizontal, 14)

            MenuSectionHeader("Controls")
            ControlGrid(model: model, selected: $selected).padding(.horizontal, 14)
            ControlDetails(model: model, control: selected ?? .mic)
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 12)

            if CalendarService.shared.current != nil {
                Divider().padding(.horizontal, 14)
                MenuSectionHeader("Calendar")
                CalendarLine(recording: MenuRecording.current(model) != nil).padding(.horizontal, 14).padding(.bottom, 8)
            }

            Divider().padding(.horizontal, 14)
            MenuSectionHeader("Recent")
            recentList.padding(.horizontal, 6).padding(.bottom, 6)

            Divider().padding(.horizontal, 14)
            VStack(spacing: 0) {
                MenuRow("Settings…", systemImage: "gearshape", shortcut: "⌘,") { showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                    .help("Open Hearsay settings")
                MenuRow("Open Hearsay", systemImage: "macwindow", shortcut: "⌘O") {
                    MainWindowController.shared.show()
                }
                .keyboardShortcut("o", modifiers: .command)
                .help("Show every meeting in the Hearsay window")
                // Open Meetings Folder and Help moved to the main window's File and Help menus:
                // five footer rows were too many (Tanner).
            }
            .padding(6)
            Divider().padding(.horizontal, 14)
            MenuRow("Quit", systemImage: "power", shortcut: "⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
                .help(model.isRecording ? "Quit: stops the recording and transcribes it next launch" : "Quit Hearsay")
                .padding(6)
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        // A thicker backing under the controls: the window panel's own material let the desktop and
        // the windows behind read through the tiles (Tanner).
        .background(.regularMaterial)
        .onAppear { model.menuOpened() }
    }

    static let helpURL = URL(string: "https://github.com/vrennat/hearsay#readme")!

    @ViewBuilder private var warnings: some View {
        let rec = MenuRecording.current(model)
        let lines: [String] = (rec.map { $0.warnings.map(\.text).sorted() } ?? [])
            + (rec == nil ? [model.lastError].compactMap { $0 } : [])
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .symbolRenderingMode(.hierarchical)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Warning: \(w)")
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 10)
        }
    }

    @ViewBuilder private var recentList: some View {
        if model.recent.isEmpty {
            // A compact empty state: `ContentUnavailableView` is sized for a window, not a menu.
            Label("No meetings yet", systemImage: "tray")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 8).frame(height: RecentRow.height, alignment: .leading)
        }
        ForEach(model.recent, id: \.id) { m in
            RecentRow(meeting: m, processing: model.queue.current == m.id, queued: model.queue.pending.contains(m.id)) {
                MeetingOpener.open(m)
            }
        }
    }

    /// `SettingsLink` does not raise an open Settings window in an accessory app: open it, then
    /// activate and bring it forward ourselves.
    private func showSettings() { Self.showSettings(openSettings) }

    static func showSettings(_ openSettings: OpenSettingsAction) {
        openSettings()
        NSApp.activate()
        DispatchQueue.main.async {
            for w in NSApp.windows where w.identifier?.rawValue.contains("Settings") == true || w.title.contains("Settings") {
                w.makeKeyAndOrderFront(nil)
                w.orderFrontRegardless()
            }
        }
    }

    static func elapsed(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: Header and primary action

struct MenuHeader: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // The app icon itself, so the panel matches the Dock and Finder.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().interpolation(.high)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            // Version lives in Settings → General (Tanner): the header is name and state only.
            Text("Hearsay").font(.headline)
            Spacer()
            status
        }
        .accessibilityElement(children: .combine)
    }

    /// Text and a symbol for every state; the colour only reinforces them.
    @ViewBuilder private var status: some View {
        Group {
            if MenuRecording.current(model) != nil {
                Label("Recording", systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
                    // Breathe is SF Symbols' "ongoing recording session" animation (HIG, SF Symbols > Animations).
                    .symbolEffect(.breathe, isActive: !reduceMotion)
            } else if !model.queue.isIdle {
                Label(model.queue.busy.count > 1 ? "Transcribing \(model.queue.busy.count)" : "Transcribing",
                      systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                    .symbolEffect(.rotate, isActive: !reduceMotion)
            } else {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .symbolRenderingMode(.hierarchical)
    }
}

struct PrimaryAction: View {
    let model: AppModel
    let recording: MenuRecording?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = recording {
                Button { model.stop() } label: {
                    Label("Stop Recording", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                // Bordered with a red tint, not prominent: a full red slab read as blown out (Tanner).
                .buttonStyle(.bordered).tint(.red).foregroundStyle(.red).controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .help("Stop recording and transcribe the meeting (Return)")
                // Below the button, not above, so Start and Stop sit in the same place (Tanner).
                HStack(alignment: .firstTextBaseline) {
                    Text(s.title).font(.body.weight(.medium)).lineLimit(1).truncationMode(.tail)
                    Spacer()
                    Text(MenuContent.elapsed(s.elapsed)).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("Elapsed")
                        .accessibilityValue(ElapsedLabel.spoken(s.elapsed))
                }
                .accessibilityElement(children: .combine)
            } else {
                Button { model.start() } label: {
                    Label("Start Recording", systemImage: "record.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .help(CalendarService.shared.current.map { "Start recording “\($0.title)” (Return)" } ?? "Start recording a meeting (Return)")
            }
            // Consent stays the user's job (Tanner): the reminder sits with Start and Stop in every state.
            Text(Consent.reminder)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(Consent.detail)
        }
    }
}

struct MenuSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: Control tiles

enum MenuControl: Hashable, CaseIterable { case mic, call, live, pill, dictation, cleanup }

/// Mic and Call audio are status tiles; Live window opens the window; Timer, Dictation and Cleanup toggle
/// the same `Prefs` keys as Settings. Six tiles fill the 3-column grid (five left a hole: Tanner).
struct ControlGrid: View {
    let model: AppModel
    @Binding var selected: MenuControl?
    @AppStorage(Prefs.notchPill, store: Prefs.defaults) private var notchPill = true
    @AppStorage(Prefs.dictation, store: Prefs.defaults) private var dictation = false
    @AppStorage(Prefs.cleanup, store: Prefs.defaults) private var cleanup = true

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(MenuControl.allCases, id: \.self) { c in
                let info = ControlInfo(c, model: model, notchPill: notchPill, dictation: dictation, cleanup: cleanup)
                ControlTile(info: info, selected: selected == c) {
                    selected = c
                    switch c {
                    case .mic, .call: break
                    case .live: LiveWindowController.shared.show()
                    case .pill: notchPill.toggle()
                    case .dictation:
                        dictation.toggle()
                        DictationController.shared.settingsChanged()
                    case .cleanup: cleanup.toggle()
                    }
                }
                .disabled(info.disabled)
                .onHover { if $0 { selected = c } }
            }
        }
    }
}

/// What a tile shows and says, derived from the session and settings.
@MainActor
struct ControlInfo {
    enum Tone { case on, off, warning }
    let title: String
    let symbol: String
    let state: String
    let tone: Tone
    let isToggle: Bool
    let disabled: Bool
    let level: Float?
    let help: String
    let details: String

    init(_ c: MenuControl, model: AppModel, notchPill: Bool, dictation: Bool, cleanup: Bool) {
        let s = MenuRecording.current(model)
        switch c {
        case .mic:
            let warns = s?.warnings.filter { if case .tapFailed = $0 { return false }; return true } ?? []
            title = "Mic"; isToggle = false; disabled = false; level = s?.micLevel
            if !warns.isEmpty {
                symbol = "mic.slash.fill"; state = "No audio"; tone = .warning
                details = warns.map(\.text).sorted().joined(separator: ". ") + ". Check the input device in System Settings > Sound."
            } else if let s {
                symbol = "mic.fill"; state = s.micActive ? "Hearing" : "Quiet"; tone = .on
                details = s.micActive ? "Your microphone is picking up sound." : "Your microphone is connected but quiet."
            } else {
                symbol = "mic"; state = "Off"; tone = .off
                details = "Your microphone is recorded with every meeting, along with call audio."
            }
        case .call:
            let failed = s?.warnings.first { if case .tapFailed = $0 { return true }; return false }
            title = "Call audio"; isToggle = false; disabled = false; level = s?.systemLevel
            if let failed {
                symbol = "speaker.slash.fill"; state = "Failed"; tone = .warning
                details = failed.text + "."
            } else if let s {
                symbol = "speaker.wave.3.fill"; state = s.callActive ? "Playing" : "Quiet"; tone = .on
                details = s.callActive ? "Hearing other apps: the call’s side of the meeting."
                                       : "Nothing is playing in other apps right now."
            } else {
                symbol = "speaker.wave.3"; state = "Off"; tone = .off
                details = "Other apps’ sound (Zoom, Meet, FaceTime) is recorded too, but not Hearsay’s own."
            }
        case .live:
            title = "Live window"; symbol = "text.bubble"; isToggle = false; level = nil
            disabled = s == nil; tone = s == nil ? .off : .on
            state = s == nil ? "Not recording" : "Open"
            details = "The transcript as it is spoken. Name speakers while the meeting runs."
        case .pill:
            // "Timer" is the user-facing name of the notch pill (Tanner asked for something other than
            // "notch pill"; code and the pref key keep the old name).
            title = "Timer"; symbol = "timer"; isToggle = true; level = nil
            disabled = false; tone = notchPill ? .on : .off; state = notchPill ? "On" : "Off"
            details = "Elapsed time and a level meter at the top of the screen. Applies from the next recording."
        case .dictation:
            // Previews run as test instances but should show the panel as people see it.
            let test = model.options.isTestInstance && !ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--preview-") }
            title = "Dictation"; symbol = dictation ? "waveform.badge.mic" : "waveform"; isToggle = true; level = nil
            disabled = test; tone = dictation && !test ? .on : .off
            state = test ? "Unavailable" : (dictation ? "On" : "Off")
            details = test ? "Dictation is off in test instances."
                           : "Hold \(DictationKey.current.title) anywhere and talk; release to paste the text."
        case .cleanup:
            title = "Cleanup"; symbol = cleanup ? "text.badge.checkmark" : "text.badge.minus"; isToggle = true; level = nil
            disabled = false; tone = cleanup ? .on : .off; state = cleanup ? "On" : "Off"
            details = "Drop fillers and repeated words from transcripts. The raw transcript keeps them."
        }
        help = "\(title): \(state). \(details)"
    }
}

struct ControlTile: View {
    let info: ControlInfo
    let selected: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                glyph
                    .frame(width: 32, height: 32)
                    .background(circleFill, in: Circle())
                    .overlay(Circle().stroke(circleColor.opacity(0.45), lineWidth: 2).scaleEffect(1 + pulse))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pulse)
                    .padding(.bottom, 2)
                Text(info.title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Text(info.state).font(.caption2).foregroundStyle(info.tone == .warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(selected ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.fill.quaternary),
                        in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                                  lineWidth: selected || contrast == .increased ? 1 : 0)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(info.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(info.title)
        .accessibilityValue(info.state)
        .accessibilityHint(info.details)
        .accessibilityAddTraits(info.isToggle ? [.isButton, .isToggle] : .isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    static let radius: CGFloat = 12

    /// The symbol swaps with Magic Replace when a toggle flips; the speaker's waves fill with the call
    /// level (variable colour, the HIG's use for a changing level). Without a level the full symbol shows.
    private var glyph: some View {
        Image(systemName: info.symbol, variableValue: variable)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(info.tone == .off ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
    }

    private var variable: Double? {
        guard info.tone == .on, info.symbol.hasPrefix("speaker.wave"), let level = info.level else { return nil }
        return Double(MeterState.norm(level))
    }

    private var circleColor: Color {
        switch info.tone { case .on: .accentColor; case .off: .secondary; case .warning: .orange }
    }

    private var circleFill: AnyShapeStyle {
        info.tone == .off ? AnyShapeStyle(.quaternary) : AnyShapeStyle(circleColor)
    }

    /// The ring grows with the stream's level (0 at -60 dBFS, 0.3 at -12), so a live stream breathes.
    private var pulse: CGFloat {
        guard info.tone == .on, let level = info.level, !reduceMotion else { return 0 }
        return CGFloat(MeterState.norm(level)) * 0.3
    }
}

/// The card under the tiles: the hovered or last chosen control, described in a sentence.
struct ControlDetails: View {
    let model: AppModel
    let control: MenuControl
    @AppStorage(Prefs.notchPill, store: Prefs.defaults) private var notchPill = true
    @AppStorage(Prefs.dictation, store: Prefs.defaults) private var dictation = false
    @AppStorage(Prefs.cleanup, store: Prefs.defaults) private var cleanup = true

    var body: some View {
        let info = ControlInfo(control, model: model, notchPill: notchPill, dictation: dictation, cleanup: cleanup)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(info.title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Text(info.state).font(.callout).lineLimit(1)
                    .foregroundStyle(info.tone == .warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            // Always two lines tall, whatever the text, so hovering a tile never reflows the panel.
            // The full sentence is also the tile's tooltip and accessibility hint.
            Text(info.details).font(.callout).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: ControlTile.radius, style: .continuous))
        .help(info.details)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Rows

/// A menu-style row: symbol, title, shortcut; highlighted on hover like a native menu item.
struct MenuRow: View {
    let title: String
    let systemImage: String
    var shortcut: String? = nil
    let action: () -> Void

    init(_ title: String, systemImage: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.shortcut = shortcut; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).frame(width: 18).accessibilityHidden(true)
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(.secondary).accessibilityHidden(true) }
            }
        }
        .buttonStyle(MenuRowStyle())
        .accessibilityLabel(title)
    }
}

struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { RowBody(configuration: configuration) }

    struct RowBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body)
                .foregroundStyle(hovering && isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 8).frame(minHeight: 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering && isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 6))
                .opacity(configuration.isPressed ? 0.8 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// A recent meeting: status symbol and word (never colour alone), title, and when it started.
struct RecentRow: View {
    let meeting: Meeting
    let processing: Bool
    let queued: Bool
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Fixed so the list never compresses: two text lines plus padding.
    static let height: CGFloat = 36

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint).frame(width: 18).accessibilityHidden(true)
                    .symbolEffect(.rotate, isActive: processing && !reduceMotion)
                    .symbolEffect(.breathe, isActive: meeting.status == .recording && !processing && !reduceMotion)
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.title).lineLimit(1).truncationMode(.tail)
                    Text(subtitle).font(.caption).opacity(0.75).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(height: Self.height)
        }
        .buttonStyle(MenuRowStyle())
        .help("Open “\(meeting.title)”: \(status)")
        .accessibilityLabel(meeting.title)
        .accessibilityValue(subtitle)
        .accessibilityHint("Opens the meeting window")
    }

    private var subtitle: String {
        "\(meeting.startedAt.formatted(.relative(presentation: .named))) · \(status)"
    }

    var status: String { MeetingStatusSymbol.word(meeting, processing: processing, queued: queued) }

    private var symbol: String {
        MeetingStatusSymbol.name(meeting, processing: processing, queued: queued)
    }

    private var tint: Color {
        switch meeting.status {
        case .recording: .red
        case .failed: .orange
        default: .secondary
        }
    }
}

/// The current calendar event (looked up at most once a minute when the menu opens), or the meeting's.
struct CalendarLine: View {
    let recording: Bool
    var body: some View {
        if let e = CalendarService.shared.current {
            Label {
                HStack(spacing: 6) {
                    Text(e.title.isEmpty ? "Untitled event" : e.title).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("until \(e.end.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary).fixedSize()
                }
            } icon: { Image(systemName: "calendar").foregroundStyle(.secondary) }
            .font(.callout)
            .accessibilityElement(children: .combine)
            .help(recording ? "Calendar event now" : "Start Recording uses this title and its guest list")
        }
    }
}

/// A meeting's status as a word and a symbol, shared by the menu's recent rows and the meeting window
/// so the two never disagree. Colour only reinforces the word.
enum MeetingStatusSymbol {
    static func word(_ m: Meeting, processing: Bool = false, queued: Bool = false) -> String {
        if processing { return "Transcribing" }
        if queued { return "Queued" }
        switch m.status {
        case .recording: return "Recording"
        case .recorded: return "Waiting to transcribe"
        case .processing: return "Transcribing"
        case .done: return m.error == "interrupted" ? "Interrupted" : "Transcribed"
        case .failed: return "Failed"
        }
    }

    static func name(_ m: Meeting, processing: Bool = false, queued: Bool = false) -> String {
        if processing { return "arrow.triangle.2.circlepath" }
        if queued { return "clock" }
        switch m.status {
        case .recording: return "record.circle.fill"
        case .recorded: return "clock"
        case .processing: return "arrow.triangle.2.circlepath"
        case .done: return m.error == nil ? "doc.text" : "exclamationmark.triangle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

/// What the menu shows about a recording, from the live session or, for a preview snapshot, from
/// `MenuPreview.recording` (a `RecordingSession` needs real capture to exist).
struct MenuRecording {
    var title: String
    var elapsed: TimeInterval
    var micLevel: Float
    var systemLevel: Float
    var warnings: Set<RecordingSession.Warning>
    var micActive: Bool { micLevel > AudioLevel.floor }
    var callActive: Bool { systemLevel > AudioLevel.floor }

    @MainActor static func current(_ model: AppModel) -> MenuRecording? {
        if let s = model.session {
            return MenuRecording(title: s.meeting.title, elapsed: s.elapsed, micLevel: s.micLevel,
                                 systemLevel: s.systemLevel, warnings: s.warnings)
        }
        return MenuPreview.recording
    }
}
