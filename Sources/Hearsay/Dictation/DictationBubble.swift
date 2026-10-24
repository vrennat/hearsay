import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class DictationBubbleModel {
    var text = ""
    var note: String?
    var listening = true
}

/// The small bubble near the bottom of the screen showing streaming words while dictating. A
/// borderless, non-activating panel that never takes focus, so the paste lands in the user's app.
@MainActor
final class DictationBubble {
    static let shared = DictationBubble()
    let model = DictationBubbleModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    static let size = NSSize(width: 460, height: 64)

    func show() {
        hideWork?.cancel()
        model.text = ""
        model.note = nil
        model.listening = true
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.isFloatingPanel = true
            p.level = .statusBar
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let container = NSView(frame: NSRect(origin: .zero, size: Self.size))
            let host = NSHostingView(rootView: DictationBubbleView(model: model))
            host.sizingOptions = []
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
            p.contentView = container
            panel = p
        }
        if let screen = NSScreen.main ?? NSScreen.screens.first, let panel {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - Self.size.width / 2, y: f.minY + 80))
        }
        panel?.orderFrontRegardless()
        Announce.post("Dictation listening")
    }

    func update(_ text: String) { model.text = text }

    /// Shows `note` (if any) for `seconds`, then hides.
    func finish(note: String? = nil, after seconds: Double = 0) {
        model.listening = false
        model.note = note
        if let note { Announce.post(note) }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.panel?.orderOut(nil) } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// Floating glass, the macOS 26+ material for transient panels; with Reduce Transparency the system
/// renders the glass opaque. The state is in words ("Listening…", the note), the red symbol only adds to it.
struct DictationBubbleView: View {
    let model: DictationBubbleModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.note != nil ? "doc.on.clipboard" : "waveform")
                .foregroundStyle(model.listening ? Color.red : Color.secondary)
                .symbolEffect(.variableColor.iterative, isActive: model.listening && !reduceMotion)
                .accessibilityHidden(true)
            Text(model.note ?? (model.text.isEmpty ? "Listening…" : model.text))
                .lineLimit(2).truncationMode(.head)
                .foregroundStyle(model.text.isEmpty && model.note == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(width: DictationBubble.size.width, height: DictationBubble.size.height)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.listening ? "Dictation, listening" : "Dictation")
        .accessibilityAddTraits(.updatesFrequently)
    }
}
