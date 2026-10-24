import AppKit
import HearsayCore
import SwiftUI

/// The Live window: live lines with speaker labels (auto-scrolling) and the live speakers. Clicking a
/// speaker row or a line's label opens a rename popover, which also shows "Sounds like X" hints.
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
    @State private var editing: String?
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

    private var speakerList: some View {
        List {
            Section("Speakers") {
                if model.speakers.isEmpty { Label("Nobody yet", systemImage: "person.2.slash").foregroundStyle(.secondary) }
                ForEach(model.speakers) { s in
                    Button { editing = s.id } label: {
                        HStack {
                            Image(systemName: s.stream == .mic ? "mic" : "phone")
                                .foregroundStyle(.secondary).frame(width: 16)
                                .accessibilityLabel(s.stream == .mic ? "In the room" : "On the call")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.label(s.id)).lineLimit(1)
                                if model.names[s.id] == nil, let h = model.hints[s.id] {
                                    Text("Sounds like \(h.name)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(Self.duration(s.talkSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Name this speaker")
                    .help("Click to name this speaker")
                    .popover(isPresented: binding(s.id), arrowEdge: .trailing) { RenamePopover(model: model, id: s.id) { editing = nil } }
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
                            Button { editing = "line:\(i)" } label: {
                                Text(model.label(line.speaker)).fontWeight(.semibold)
                                    .foregroundStyle(line.stream == .mic ? Color.accentColor : Color.purple)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Name this speaker")
                            .help("Click to name this speaker")
                            .popover(isPresented: binding("line:\(i)"), arrowEdge: .bottom) {
                                RenamePopover(model: model, id: line.speaker) { editing = nil }
                            }
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

    private func binding(_ key: String) -> Binding<Bool> {
        Binding(get: { editing == key }, set: { if !$0, editing == key { editing = nil } })
    }

    static func duration(_ s: Double) -> String { MenuContent.elapsed(s) }
}

struct RenamePopover: View {
    let model: LiveModel
    let id: String
    let done: () -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name \(LiveModel.defaultLabel(id))").font(.headline)
            TextField("First name", text: $text).textFieldStyle(.roundedBorder).frame(width: 220)
                .onSubmit(save)
                .accessibilityLabel("Name for \(LiveModel.defaultLabel(id))")
            if let h = model.hints[id] {
                Button { text = h.name } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sounds like \(h.name)").font(.callout)
                        Text("“\(h.quote)”").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .buttonStyle(.plain)
                .help("A suggestion from how people addressed this voice. Click to use it.")
                .accessibilityLabel("Suggestion: sounds like \(h.name)")
            }
            HStack {
                if model.names[id] != nil { Button("Clear") { text = ""; save() } }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .onAppear { text = model.names[id] ?? "" }
    }

    private func save() {
        model.rename(id, to: text)
        done()
    }
}
