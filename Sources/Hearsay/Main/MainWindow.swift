import AppKit
import HearsayCore
import SwiftUI

/// The main "Hearsay" window: a meetings browser. An NSWindow rather than a SwiftUI `Window` scene,
/// because it is shown from AppKit paths (Dock reopen, notifications, the menu bar extra's rows) that
/// have no `openWindow` action, and the meeting and live windows already work this way.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()
    private(set) var window: NSWindow?

    @discardableResult
    func show() -> NSWindow {
        let w = window ?? make()
        MainWindowModel.shared.refresh()
        AppWindows.willShow()
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        WindowInventory.log("main window")
        return w
    }

    /// `MeetingOpener`'s route: select the meeting in the sidebar and bring the window front.
    @discardableResult
    func show(_ meeting: Meeting) -> NSWindow {
        let w = show()
        MainWindowModel.shared.select(meeting.id)
        return w
    }

    private func make() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 720),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Hearsay"
        w.isReleasedWhenClosed = false
        w.toolbarStyle = .unified
        if CommandLine.arguments.contains("--preview-dark") { w.appearance = NSAppearance(named: .darkAqua) }
        if CommandLine.arguments.contains("--preview-light") { w.appearance = NSAppearance(named: .aqua) }
        // Hosting view in a plain container, as for the pill and the live window; the view's
        // `.toolbar` and `.searchable` become the window's NSToolbar.
        let container = NSView(frame: w.contentRect(forFrameRect: w.frame))
        let host = NSHostingView(rootView: MainWindowView(model: MainWindowModel.shared))
        host.sizingOptions = []
        host.sceneBridgingOptions = [.toolbars]
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        w.contentView = container
        // Sidebar (220) + transcript (400) + inspector (240) + dividers: narrower squeezes the transcript.
        w.contentMinSize = NSSize(width: 880, height: 480)
        w.center()
        w.setFrameAutosaveName("HearsayMainWindow")  // restores the saved frame when there is one
        // A frame saved under an older, smaller minimum is not grown by AppKit on restore.
        let content = w.contentRect(forFrameRect: w.frame)
        if content.width < w.contentMinSize.width || content.height < w.contentMinSize.height {
            w.setContentSize(NSSize(width: max(content.width, 1180), height: max(content.height, 720)))
            w.center()
        }
        w.delegate = self
        window = w
        return w
    }

    func windowWillClose(_ notification: Notification) {
        // Stop playback; the selection is not restored next time.
        MainWindowModel.shared.selection = nil
    }
}

struct MainWindowView: View {
    @Bindable var model: MainWindowModel

    var body: some View {
        NavigationSplitView {
            MeetingSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            if let d = model.detail {
                MeetingView(model: d).id(d.id)
            } else if model.groups.isEmpty && model.search.trimmingCharacters(in: .whitespaces).isEmpty {
                // First run: one welcome instead of two empty states that say the same thing.
                ContentUnavailableView {
                    Label("Record Your First Meeting", systemImage: "waveform")
                } description: {
                    Text("Hearsay records your mic and call audio, then transcribes the meeting on this Mac. \(Consent.reminder)")
                } actions: {
                    Button("Start Recording") { MainWindowModel.startRecording() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("n")
                        .help("Start recording a meeting")
                }
            } else {
                ContentUnavailableView("No Meeting Selected", systemImage: "rectangle.stack",
                                       description: Text("Choose a meeting from the sidebar."))
            }
        }
        .toolbar { MainToolbar(model: model) }
    }
}

struct MainToolbar: ToolbarContent {
    let model: MainWindowModel

    var body: some ToolbarContent {
        // Separate items (not one group) so the toolbar renders two controls, with Record as the
        // primary action on the trailing edge, like Voice Memos.
        ToolbarItem(placement: .primaryAction) {
            Button { LiveWindowController.shared.show() } label: { Label("Live Window", systemImage: "text.bubble") }
                .help("Show the transcript as it is spoken")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            if AppModel.shared.isRecording {
                Button { AppModel.shared.stop() } label: { Label("Stop Recording", systemImage: "stop.fill") }
                    .tint(.red)
                    .help("Stop recording and transcribe the meeting")
            } else {
                Button { MainWindowModel.startRecording() } label: { Label("Start Recording", systemImage: "record.circle") }
                    .help("Start recording a meeting. \(Consent.reminder)")
            }
        }
    }
}

extension MainWindowModel {
    /// Start, then select the new meeting so its detail (the "recording" state) shows.
    static func startRecording() {
        Task { @MainActor in
            guard await AppModel.shared.startRecording(), let id = AppModel.shared.session?.meetingID else { return }
            shared.select(id)
        }
    }
}

struct MeetingSidebar: View {
    @Bindable var model: MainWindowModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        let groups = model.groups
        List(selection: $model.selection) {
            ForEach(groups) { g in
                Section(g.title) {
                    ForEach(g.meetings, id: \.id) { m in
                        MeetingListRow(meeting: m, recording: g.id == "recording",
                                       processing: AppModel.shared.queue.current == m.id,
                                       queued: AppModel.shared.queue.pending.contains(m.id))
                            .tag(m.id)
                            .contextMenu { menu(m) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            // No-meetings case is handled by the detail's welcome; only a failed search says so here.
            if groups.isEmpty, !model.search.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView.search(text: model.search)
            }
        }
        .searchable(text: $model.search, placement: .sidebar, prompt: "Search meetings")
        .searchFocused($searchFocused)
        .onReceive(NotificationCenter.default.publisher(for: .hearsayFindMeetings)) { _ in searchFocused = true }
        .confirmationDialog(deleteTitle, isPresented: deleteShown, titleVisibility: .visible, presenting: model.pendingDelete) { m in
            Button("Move to Trash", role: .destructive) { model.trash(m) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its audio, transcript and notes go to the Trash. You can put them back from Finder.")
        }
    }

    @ViewBuilder private func menu(_ m: Meeting) -> some View {
        Button("Show in Finder") { AppModel.shared.reveal(m) }
        Button("Copy Markdown Path") { model.copyMarkdownPath(m) }
            .disabled(model.markdownURL(m) == nil)
        Divider()
        Button("Move to Trash…", role: .destructive) { model.pendingDelete = m }
            .disabled(model.isBusy(m))
    }

    private var deleteTitle: String {
        "Move “\(model.pendingDelete.map(MeetingListRow.title) ?? "")” to the Trash?"
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } })
    }
}

extension Notification.Name {
    /// Edit > Find Meetings (⌘F): focuses the sidebar search field.
    static let hearsayFindMeetings = Notification.Name("HearsayFindMeetings")
}

struct MeetingListRow: View {
    let meeting: Meeting
    let recording: Bool
    let processing: Bool
    let queued: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func title(_ m: Meeting) -> String { m.title.isEmpty ? "Untitled meeting" : m.title }

    private var word: String { recording ? "Recording" : MeetingStatusSymbol.word(meeting, processing: processing, queued: queued) }
    private var time: String { meeting.startedAt.formatted(date: .omitted, time: .shortened) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: recording ? "record.circle.fill" : MeetingStatusSymbol.name(meeting, processing: processing, queued: queued))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(recording ? AnyShapeStyle(.red) : meeting.status == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .symbolEffect(.breathe, isActive: recording && !reduceMotion)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(meeting)).lineLimit(1)
                Group {
                    if recording {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text("Recording · \(MenuContent.elapsed(ctx.date.timeIntervalSince(meeting.startedAt)))")
                                .help(Consent.reminder)
                                .monospacedDigit()
                        }
                    } else {
                        Text("\(time) · \(word)")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.title(meeting)), \(recording ? "recording now" : "\(time), \(word)")")
        .help("\(meeting.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(word)")
    }
}
