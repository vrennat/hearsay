import AppKit
import HearsayCore
import SwiftUI

/// One meeting: header, transport row and transcript, with speakers and files in a trailing
/// inspector. The main window's detail pane.
struct MeetingView: View {
    @Bindable var model: MeetingModel
    @State private var search = ""
    @AppStorage("meetingInspectorShown") private var inspectorShown = true
    /// The pane's width. Below `inspectorFits` the inspector steps aside instead of forcing the split
    /// view wider, which shoved the sidebar off the window's edge when a meeting was selected.
    @State private var paneWidth: CGFloat = 0  // inspector waits for the first measurement rather than overflowing
    static let minTranscript: CGFloat = 320
    private var inspectorFits: Bool { paneWidth >= Self.minTranscript + 240 + 1 }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if let banner = model.banner {
                    Label(banner, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.orange.opacity(0.12))
                }
                MeetingHeader(model: model).padding(.horizontal, 16).padding(.vertical, 12)
                Divider()
                if model.isRecording {
                    // The live transcript and its speakers replace playback and the inspector.
                    LiveRecordingPane(model: LiveModel.shared, search: search)
                } else {
                    PlaybackBar(model: model).padding(.horizontal, 12).padding(.vertical, 8)
                    SpeakerTimeline(model: model).padding(.horizontal, 16).padding(.bottom, 10)
                    Divider()
                    TranscriptPanel(model: model, query: search)
                }
            }
            .frame(minWidth: Self.minTranscript, maxWidth: .infinity)
            if inspectorShown, inspectorFits, !model.isRecording {
                // A fixed trailing column rather than `.inspector`: inside this NavigationSplitView
                // (hosted in an NSWindow) `.inspector` crashed AppKit's constraint pass below about
                // 1,100 pt wide, even with Text("x") as its content. See CLAUDE.md, Meeting UI.
                Divider()
                MeetingInspector(model: model)
                    .frame(width: 240)
                    // Not under the toolbar: there a lighter column would cut a seam through the search field.
                    .background(.background.secondary, ignoresSafeAreaEdges: [])
                    .transition(reduceMotion ? .identity : .move(edge: .trailing))
            }
        }
        .frame(minHeight: 360)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { paneWidth = $0 }
        .background(Color(nsColor: .windowBackgroundColor))
        .searchable(text: $search, placement: .toolbar, prompt: "Search transcript")
        .toolbar {
            // Spacers split the window's Live/Record pair, this meeting's actions and the inspector
            // toggle into three groups instead of one long pill.
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Button { AppModel.shared.reveal(model.meeting) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Show this meeting's folder in Finder")
                Button { model.reprocess() } label: {
                    Label("Reprocess", systemImage: "arrow.clockwise")
                }
                .disabled(!model.canReprocess)
                .help(model.isQueued ? "Processing…" : (model.meeting.audioRemovedAt != nil ? "Audio was removed by retention" : "Transcribe this meeting again"))
            }
            // HIG: the inspector's toggle sits at the trailing end of the toolbar.
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { inspectorShown.toggle() } } label: {
                    Label(inspectorShown ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(!inspectorFits ? "Widen the window to show speakers and files"
                      : inspectorShown ? "Hide speakers and files (⌥⌘I)" : "Show speakers and files (⌥⌘I)")
                .disabled(!inspectorFits || model.isRecording)
            }
        }
    }
}

struct MeetingHeader: View {
    let model: MeetingModel
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain).font(.title2.weight(.semibold))
                    .onSubmit { model.setTitle(title) }
                    .accessibilityLabel("Meeting title")
                    .help("Edit the title and press Return to save")
                Spacer()
                let word = model.statusWord
                Label(word, systemImage: model.statusSymbol)
                    .fixedSize()
                    .symbolRenderingMode(.hierarchical)
                    .font(.callout).foregroundStyle(model.meeting.status == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Status: \(word)")
            }
            HStack(spacing: 12) {
                Text(model.meeting.startedAt.formatted(date: .abbreviated, time: .shortened)).lineLimit(1).fixedSize()
                if let d = model.meeting.duration, d > 0 {
                    Text(MenuContent.elapsed(d)).monospacedDigit().lineLimit(1).fixedSize().accessibilityLabel("Duration \(ElapsedLabel.spoken(d))")
                }
                if !model.meeting.attendees.isEmpty {
                    Label(model.meeting.attendees.joined(separator: ", "), systemImage: "person.2")
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            if let e = model.editError {
                Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { title = model.meeting.title }
        .onChange(of: model.meeting.title) { _, t in title = t }
    }
}

/// The trailing inspector: speakers (with rename) and the meeting's files.
struct MeetingInspector: View {
    let model: MeetingModel

    var body: some View {
        // A plain scroll view rather than a grouped Form: inspector sections read like Xcode's and
        // Finder's (header, rows, divider), and the preview snapshot can draw it.
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                InspectorHeader("Speakers")
                if model.speakers.isEmpty {
                    Label("No speakers yet", systemImage: "person.2.slash").foregroundStyle(.secondary)
                }
                ForEach(model.speakers) { s in SpeakerRowView(model: model, row: s) }
                if let note = model.summaryNote {
                    // Why on-device summaries are missing (model unavailable, still downloading, …).
                    Label(note, systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider().padding(.vertical, 4)
                InspectorHeader("Files")
                if model.files.isEmpty {
                    Text("No files").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.files, id: \.self) { FileRow(url: $0, folder: model.store.folder(model.id)) }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct InspectorHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(.headline).accessibilityAddTraits(.isHeader)
    }
}

/// "Move to": the other speakers on the line's side, then a new speaker. For a quiet person whose few
/// lines diarization folded into someone else's.
struct MoveLineMenu: View {
    let model: MeetingModel
    let line: TranscriptLines.Line

    var body: some View {
        Section("Move this line to") {
            ForEach(model.moveTargets(for: line)) { s in
                Button(s.name ?? s.label) { model.move(line, to: s.id) }
            }
            Button("New Speaker") { model.move(line, to: nil) }
        }
    }
}

struct SpeakerRowView: View {
    let model: MeetingModel
    let row: MeetingModel.SpeakerRow
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: row.stream == .mic ? "mic.fill" : "phone.fill").foregroundStyle(model.color(for: row.id)).frame(width: 16)
                    .accessibilityLabel(row.stream == .mic ? "In the room" : "On the call")
                Text(model.canRename ? row.label : (row.name ?? row.label))
                    .font(model.canRename ? .caption : .body)
                    .foregroundStyle(model.canRename ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Spacer()
                Text(MenuContent.elapsed(row.talkSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityLabel("Talked \(ElapsedLabel.spoken(row.talkSeconds))")
            }
            .accessibilityElement(children: .combine)
            TalkShareBar(share: model.talkShare(row.id), color: model.color(for: row.id))
            if model.canRename {
                TextField("Name", text: $text, prompt: Text("Name \(row.label)"))
                    .textFieldStyle(.roundedBorder).labelsHidden()
                    .onSubmit { model.rename(row.id, to: text) }
                    .accessibilityLabel("Name for \(row.label)")
                    .help("Type a name and press Return to save")
                if row.name != nil, model.isGuess(row.id) {
                    HStack(spacing: 6) {
                        Label("Guessed", systemImage: "questionmark.circle").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("Confirm", systemImage: "checkmark") { model.confirm(row.id) }
                            .controlSize(.small)
                            .help("This name is right. Confirmed names help recognise this voice in other meetings.")
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            if row.name == nil {
                if let h = model.hints[row.id] {
                    Button { text = h.name } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Sounds like \(h.name)").font(.caption)
                            Text("“\(h.quote)”").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Suggestion: sounds like \(h.name)")
                    .accessibilityHint("Fills the name field. Press Return in the field to save.")
                    .help("A suggestion from how people addressed this voice. Click to use it, then press Return.")
                }
                if let summary = model.summaries[row.id] {
                    Text(summary).font(.caption).foregroundStyle(.secondary).italic()
                        .fixedSize(horizontal: false, vertical: true)
                        .help("On-device summary of what this voice said; a naming hint, never saved.")
                }
            }
        }
        .onAppear { text = row.name ?? "" }
        .onChange(of: row.name) { _, n in text = n ?? "" }
    }
}

/// Transport row: play/pause, time, a slider taking the free width, the source picker and Follow.
/// Everything but the slider is fixed-size, so nothing wraps however narrow the pane gets.
struct PlaybackBar: View {
    @Bindable var model: MeetingModel

    var body: some View {
        if let p = model.player {
            // Full row first; narrower, drop the time readout and Follow's title; narrowest, the
            // source picker becomes a pop-up menu.
            ViewThatFits(in: .horizontal) {
                transport(p, compact: false)
                transport(p, compact: true)
                transport(p, compact: true, menuPicker: true)
            }
            .frame(minHeight: 28)
        } else if model.isRecording {
            // The recording empty state below already says so; a second strip was noise.
            EmptyView()
        } else {
            HStack(spacing: 10) {
                Image(systemName: "speaker.slash").foregroundStyle(.secondary).accessibilityHidden(true)
                Text(model.meeting.audioRemovedAt != nil ? "Audio was removed by retention."
                     : model.meeting.streams.isEmpty ? "No audio." : "Loading audio…")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .frame(minHeight: 28)
        }
    }

    private func transport(_ p: MeetingPlayer, compact: Bool, menuPicker: Bool = false) -> some View {
        HStack(spacing: 10) {
            Button { p.toggle() } label: {
                Label(p.isPlaying ? "Pause" : "Play", systemImage: p.isPlaying ? "pause.fill" : "play.fill")
                    .labelStyle(.iconOnly).frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless).controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])
            .help(p.isPlaying ? "Pause (Space)" : "Play (Space)")
            if !compact {
                Text("\(MenuContent.elapsed(p.time)) / \(MenuContent.elapsed(p.duration))")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize()
                    .accessibilityHidden(true)
            }
            Slider(value: Binding(get: { p.time }, set: { p.seek(to: $0) }), in: 0...max(p.duration, 0.1))
                .frame(minWidth: compact ? 40 : 120, maxWidth: .infinity)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(ElapsedLabel.spoken(p.time)) of \(ElapsedLabel.spoken(p.duration))")
                .help("Playback position")
            Picker("Audio source", selection: Binding(get: { p.mix }, set: { p.mix = $0 })) {
                ForEach(MeetingPlayer.Mix.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .modifier(SourcePickerStyle(menu: menuPicker))
            .disabled(p.available.count < 2)
            .help(p.available.count < 2 ? "Only one audio source was recorded" : "Play the room (Mic), the call (Call) or both")
            Toggle(isOn: $model.followPlayback) {
                if compact {
                    Label("Follow", systemImage: "text.line.first.and.arrowtriangle.forward").labelStyle(.iconOnly)
                } else {
                    Label("Follow", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
            }
            .toggleStyle(.button).fixedSize()
            .accessibilityLabel("Follow playback")
            .accessibilityHint("Scrolls the transcript to the line being played")
            .help(model.followPlayback ? "Stop scrolling the transcript with playback" : "Scroll the transcript with playback")
        }
    }
}

private struct SourcePickerStyle: ViewModifier {
    let menu: Bool
    func body(content: Content) -> some View {
        if menu {
            content.pickerStyle(.menu).labelsHidden().fixedSize()
        } else {
            content.pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }
}

struct TranscriptPanel: View {
    let model: MeetingModel
    var query = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: [TranscriptLines.Line] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.lines.lines }
        return model.lines.lines.filter {
            $0.text.localizedCaseInsensitiveContains(q) || model.displayName($0.speaker).localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if model.lines.lines.isEmpty {
                        if model.isRecording {
                            ContentUnavailableView {
                                Label("Recording", systemImage: "waveform")
                            } description: {
                                Text("The transcript appears here after you stop. \(Consent.reminder)")
                            }
                        } else {
                            ContentUnavailableView("No Transcript Yet", systemImage: "text.bubble",
                                                   description: Text(model.isQueued ? "This meeting is queued for transcription."
                                                                     : model.canReprocess ? "Use Reprocess in the toolbar to transcribe it."
                                                                     : "There is no audio left to transcribe."))
                        }
                    } else if model.lines.source == .live || model.lines.source == .liveMarkdown {
                        Text(model.isQueued ? "Showing the live transcript while this meeting is transcribed."
                             : "Showing the live transcript. This meeting has not been transcribed yet.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 4)
                    }
                    if !query.isEmpty, shown.isEmpty, !model.lines.lines.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                    ForEach(shown) { line in
                        let current = model.currentLine == line.id
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Button { model.player?.seek(to: line.start); model.player?.play() } label: {
                                Text(MenuContent.elapsed(line.start)).monospacedDigit().font(.callout)
                            }
                            .buttonStyle(.link)
                            .disabled(model.player == nil)
                            .frame(width: 52, alignment: .trailing)
                            .help("Play from here")
                            .accessibilityLabel("Play from \(ElapsedLabel.spoken(line.start))")
                            if model.canReassign {
                                Menu {
                                    MoveLineMenu(model: model, line: line)
                                } label: {
                                    Text(model.displayName(line.speaker)).fontWeight(.semibold).lineLimit(1).fixedSize()
                                        .foregroundStyle(model.color(for: line.speaker))
                                }
                                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                                .help("Wrong speaker? Move this line to someone else")
                                .accessibilityHint("Move this line to another speaker")
                            } else {
                                Text(model.displayName(line.speaker)).fontWeight(.semibold).lineLimit(1).fixedSize()
                                    .foregroundStyle(model.color(for: line.speaker))
                            }
                            Text(line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 2).padding(.horizontal, 4)
                        .background(current ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .contextMenu { if model.canReassign { MoveLineMenu(model: model, line: line) } }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(current ? .isSelected : [])
                        .id(line.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: model.currentLine) { _, i in
                guard let i else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(i, anchor: .center) }
            }
        }
    }
}

/// One file in the inspector: small icon and a friendly name; click shows it in Finder, the context
/// menu also offers Open. The raw path is the tooltip.
struct FileRow: View {
    let url: URL
    let folder: URL

    static func friendlyName(_ url: URL) -> String {
        let name = url.lastPathComponent
        let stem = url.deletingPathExtension().lastPathComponent
        if url.deletingLastPathComponent().lastPathComponent == "audio" {
            switch stem {
            case "mic": return "Mic audio"
            case "system": return "Call audio"
            default: return "Audio (\(name))"
            }
        }
        switch name {
        case "meeting.json": return "Meeting record"
        case "live.md": return "Live transcript"
        case "live.json": return "Live transcript data"
        case "transcript.md": return "Transcript"
        case "transcript.json": return "Transcript data"
        case "cleanup.json": return "Cleanup data"
        case "notes.md": return "Notes"
        default: return name
        }
    }

    private var relative: String {
        url.path.hasPrefix(folder.path + "/") ? String(url.path.dropFirst(folder.path.count + 1)) : url.lastPathComponent
    }

    var body: some View {
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
            HStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(Self.friendlyName(url)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .help("\(relative): click to show in Finder")
        .accessibilityLabel(Self.friendlyName(url))
        .accessibilityValue(relative)
        .accessibilityHint("Shows the file in Finder")
        .accessibilityAction(named: "Open") { NSWorkspace.shared.open(url) }
    }
}

/// The speaker's share of all talk time, as a thin bar with the percentage.
struct TalkShareBar: View {
    let share: Double
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: max(3, geo.size.width * share))
                }
            }
            .frame(height: 5)
            Text(share.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Share of talk time")
        .accessibilityValue(share.formatted(.percent.precision(.fractionLength(0))))
    }
}
