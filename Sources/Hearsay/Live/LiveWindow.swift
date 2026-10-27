import AppKit
import HearsayCore
import SwiftUI

/// The Live window: live lines with speaker labels (auto-scrolling) and the live speakers. Clicking a
/// speaker's name field (or a line's label, which focuses that field) renames it live; "Sounds like X" hints sit under the field.
@MainActor
final class LiveWindowController {
    static let shared = LiveWindowController()
    private(set) var window: NSWindow?

    @discardableResult
    func show() -> NSWindow? {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Live Transcript"
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("HearsayLiveWindow")
            // Hosting view inside a plain container, as for the pill: a hosting content view can drive
            // window resizes.
            let container = NSView(frame: w.contentRect(forFrameRect: w.frame))
            let host = NSHostingView(rootView: LiveWindowView(model: LiveModel.shared))
            host.sizingOptions = []
            host.sceneBridgingOptions = [.toolbars]  // `.searchable` becomes the window's toolbar
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
            w.contentView = container
            w.center()
            window = w
        }
        AppWindows.willShow()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        return window
    }
}

struct LiveWindowView: View {
    let model: LiveModel
    @FocusState private var focused: String?
    @State private var search = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A split view, not an HSplitView: the sidebar list style only draws its material and sits
        // under a unified toolbar correctly inside NavigationSplitView (in a bare window it bled
        // the wallpaper tint up over the title bar).
        NavigationSplitView {
            speakerList.navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 260)
        } detail: {
            lineList.frame(minWidth: 320)
        }
        .frame(minWidth: 520, minHeight: 300)
        .searchable(text: $search, placement: .toolbar, prompt: "Search live transcript")
        // Recording state as the window subtitle under "Live Transcript": the earlier bordered
        // "Recording" toolbar item read as a button and sat oddly beside the search field (Tanner).
        .navigationSubtitle(model.isRecording ? "Recording · \(Consent.reminder)" : "Not recording")
    }

    private func matches(_ line: LiveLine) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || line.text.localizedCaseInsensitiveContains(q) || model.label(line.speaker).localizedCaseInsensitiveContains(q)
    }

    /// Names are typed straight into the speaker rows (no popover): a popover in a row that redraws
    /// with every 2 s live save was easy to lose mid-word. A field saves on Return or when focus leaves.
    private var speakerList: some View {
        List {
            Section("Speakers") {
                if model.speakers.isEmpty { Label("Nobody yet", systemImage: "person.2.slash").foregroundStyle(.secondary) }
                ForEach(model.speakers) { s in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: s.stream == .mic ? "mic" : "phone")
                            .foregroundStyle(.secondary).frame(width: 16)
                            .accessibilityLabel(s.stream == .mic ? "In the room" : "On the call")
                        VStack(alignment: .leading, spacing: 2) {
                            SpeakerNameField(model: model, id: s.id, focus: $focused)
                            if model.names[s.id] == nil, let h = model.hints[s.id] {
                                Button("Sounds like \(h.name)") { model.rename(s.id, to: h.name) }
                                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                                    .help("“\(h.quote)”. Click to use this name.")
                                    .accessibilityLabel("Suggestion: sounds like \(h.name). Use it")
                            }
                        }
                        Spacer(minLength: 4)
                        Text(Self.duration(s.talkSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var lineList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.lines.enumerated()).filter { matches($0.element) }, id: \.offset) { i, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(MenuContent.elapsed(line.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                                .accessibilityLabel("At \(ElapsedLabel.spoken(line.start))")
                            Button { focused = line.speaker } label: {
                                Text(model.label(line.speaker)).fontWeight(.semibold)
                                    .foregroundStyle(line.stream == .mic ? Color.accentColor : Color.purple)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Name this speaker")
                            .help("Click to name this speaker")
                            Text(line.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(i)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .overlay {
                // Outside the lazy stack, so the empty state centres in the pane.
                if model.lines.isEmpty {
                    if model.isRecording {
                        ContentUnavailableView {
                            Label("Listening", systemImage: "waveform")
                                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                        } description: {
                            Text("Lines appear every couple of seconds. \(Consent.reminder)")
                        }
                    } else {
                        ContentUnavailableView("No Live Transcript", systemImage: "text.bubble",
                                               description: Text("Start a recording to see the transcript as it is spoken."))
                    }
                }
            }
            .onChange(of: model.lines.count) { _, _ in
                guard search.isEmpty else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    static func duration(_ s: Double) -> String { MenuContent.elapsed(s) }
}

/// One speaker's name, edited in place. Shows the default label (Room 1, Remote 2) as the placeholder;
/// an emptied field clears the name.
struct SpeakerNameField: View {
    let model: LiveModel
    let id: String
    var focus: FocusState<String?>.Binding
    @State private var text = ""

    var body: some View {
        TextField(LiveModel.defaultLabel(id), text: $text)
            .textFieldStyle(.plain)
            .focused(focus, equals: id)
            .onSubmit(save)
            .onChange(of: focus.wrappedValue) { old, new in if old == id, new != id { save() } }
            .onChange(of: model.names[id]) { _, n in if focus.wrappedValue != id { text = n ?? "" } }
            .onChange(of: text) { _, t in if focus.wrappedValue == id { model.drafts[id] = t } }
            .onAppear { text = model.names[id] ?? "" }
            .onDisappear(perform: save)  // closing the window mid-edit keeps what was typed
            .accessibilityLabel("Name for \(LiveModel.defaultLabel(id))")
            .help("Type a name, then press Return")
    }

    private func save() {
        // After Stop the meeting is over; a late save would land in the next meeting's live engines.
        guard model.isRecording else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != (model.names[id] ?? "") else { return }
        model.rename(id, to: t)
    }
}
