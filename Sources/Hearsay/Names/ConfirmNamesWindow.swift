import AppKit
import HearsayCore
import Observation
import SwiftUI

/// "Confirm Names…": everyone with a guessed or unconfirmed name, one row per person. Confirming a
/// person confirms that name in every meeting listed, so it helps recognise their voice in other
/// meetings. Names from before 0.1.3 start here, because nothing recorded which of them were guessed.
@MainActor @Observable
final class ConfirmNamesModel {
    static let shared = ConfirmNamesModel()
    private let log = HSLog("names")
    private(set) var people: [NameReview.Person] = []
    private(set) var titles: [String: String] = [:]
    private(set) var loading = false
    var error: String?

    func reload() {
        let store = AppModel.shared.store
        let me = Prefs.userNameValue
        loading = true
        Task.detached {
            let people = NameReview.pending(store: store, me: me)
            var titles: [String: String] = [:]
            for id in Set(people.flatMap { $0.entries.map(\.meetingID) }) { titles[id] = (try? store.loadMeeting(id))?.title }
            await MainActor.run {
                self.people = people; self.titles = titles; self.loading = false
            }
        }
    }

    func confirm(_ p: NameReview.Person) {
        do {
            let n = try NameReview.confirm(p.entries, name: p.name, store: AppModel.shared.store)
            log.info("Confirmed \(p.name) in \(n) places")
            error = nil
        } catch {
            self.error = "Could not confirm \(p.name): \(error)"
            log.error("Confirm \(p.name): \(error)")
        }
        reload()
    }
}

@MainActor
final class ConfirmNamesWindowController {
    static let shared = ConfirmNamesWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Confirm Names"
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("HearsayConfirmNamesWindow")
            // Hosting view inside a plain container, as for the other windows.
            let container = NSView(frame: w.contentRect(forFrameRect: w.frame))
            let host = NSHostingView(rootView: ConfirmNamesView(model: .shared))
            host.sizingOptions = []
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
            w.contentView = container
            w.center()
            window = w
        }
        ConfirmNamesModel.shared.reload()
        AppWindows.willShow()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct ConfirmNamesView: View {
    let model: ConfirmNamesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Confirm the names that are right. Only confirmed names are used to recognise people in new meetings.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
            if let e = model.error { Text(e).font(.caption).foregroundStyle(.red).padding(.horizontal, 12) }
            List {
                ForEach(model.people) { p in
                    DisclosureGroup {
                        ForEach(p.entries, id: \.meetingID) { e in
                            Button(model.titles[e.meetingID] ?? e.meetingID) {
                                if let m = try? AppModel.shared.store.loadMeeting(e.meetingID) { MeetingOpener.open(m) }
                            }
                                .buttonStyle(.link)
                                .help("Open this meeting to check or rename the speaker")
                        }
                    } label: {
                        HStack {
                            Text(p.name).fontWeight(.medium)
                            Text("\(p.entries.count) meeting\(p.entries.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                            Spacer()
                            Button("Confirm", systemImage: "checkmark") { model.confirm(p) }
                                .controlSize(.small)
                                .help("Confirm \(p.name) in every meeting listed")
                        }
                    }
                }
            }
            .overlay {
                if model.people.isEmpty, !model.loading {
                    ContentUnavailableView("Nothing to Confirm", systemImage: "checkmark.circle",
                                           description: Text("Every name is confirmed."))
                }
            }
        }
        .frame(minWidth: 360, minHeight: 260)
    }
}
