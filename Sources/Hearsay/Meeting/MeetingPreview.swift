import AppKit
import Foundation
import HearsayCore

/// Debug launch, for checking a meeting in the main window without a human:
/// `--preview-meeting ID [--preview-rename SPEAKER=NAME] [--preview-seek SECONDS] [--preview-mix Mic|Call|Both]
///  [--preview-snapshot PNG]`. Opens the main window with the meeting selected, applies the rename through the normal edit path,
/// seeks and plays for 2 s, logs the player state and the composition segments, then renders the
/// window's own view to a PNG (the agent shell cannot use `screencapture`) and quits.
@MainActor
enum MeetingPreview {
    static func startIfRequested(_ args: [String] = CommandLine.arguments) {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let id = value("--preview-meeting") else { return }
        let log = HSLog("meeting-preview")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                guard let meeting = try? AppModel.shared.store.loadMeeting(id) else {
                    log.error("No meeting \(id)"); NSApp.terminate(nil); return
                }
                let window = MainWindowController.shared.show(meeting)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard let model = MainWindowModel.shared.detail, model.id == id else { return }
                    if let r = value("--preview-rename"), let eq = r.firstIndex(of: "=") {
                        model.rename(String(r[..<eq]), to: String(r[r.index(after: eq)...]))
                        log.info("Renamed; speakerNames now \(model.meeting.speakerNames)")
                    }
                    if let p = model.player {
                        log.info("Segments: \(p.segments.map { "\($0.0.rawValue) \(String(format: "%.2f-%.2f", $0.1, $0.2))" })")
                        if let m = value("--preview-mix"), let mix = MeetingPlayer.Mix(rawValue: m) { p.mix = mix }
                        p.seek(to: Double(value("--preview-seek") ?? "0") ?? 0)
                        p.play()
                        try? await Task.sleep(for: .seconds(2))
                        log.info("Playing \(p.isPlaying) at \(String(format: "%.2f", p.time)) of \(String(format: "%.2f", p.duration)), mix \(p.mix.rawValue), current line \(model.currentLine.map(String.init) ?? "-")")
                        p.pause()
                    } else {
                        log.info("No player (recording \(model.isRecording), streams \(model.meeting.streams.count))")
                    }
                    log.info("Toolbar: \(window.toolbar.map { "\($0.items.count) items: \($0.items.map { $0.label.isEmpty ? $0.itemIdentifier.rawValue : $0.label })" } ?? "none")")
                    log.info("Hints \(model.hints.mapValues(\.name)); summaries \(model.summaries.count); note \(model.summaryNote ?? "-"); lines \(model.lines.lines.count) from \(model.lines.source.rawValue); files \(model.files.count)")
                    if let path = value("--preview-snapshot") {
                        try? await Task.sleep(for: .seconds(1))
                        snapshot(window, to: URL(fileURLWithPath: path))
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    /// `frame`: draw the window's frame view (title bar and toolbar included) instead of the content view.
    static func snapshot(_ window: NSWindow, to url: URL, frame: Bool = false) {
        guard let view = frame ? window.contentView?.superview : window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if frame, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            // The sidebar's outline view is skipped when its ancestor is cached; it draws on its own.
            func tables(_ v: NSView) -> [NSTableView] { (v as? NSTableView).map { [$0] } ?? v.subviews.flatMap(tables) }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            for t in tables(view) {
                let r = t.visibleRect
                guard let tr = t.bitmapImageRepForCachingDisplay(in: r) else { continue }
                t.cacheDisplay(in: r, to: tr)
                tr.draw(in: view.convert(r, from: t), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        HSLog("meeting-preview").info("Snapshot \(url.path) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
    }
}
