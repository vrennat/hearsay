import AppKit
import HearsayCore
import SwiftUI

/// Debug launch for checking the menu and Settings headless (the agent shell has no Screen Recording
/// permission, so these render the window's own view, as the pill and meeting previews do):
/// `--preview-menu --preview-snapshot PNG` renders the menu panel (with `--preview-menu-style panel`;
/// in the default `menu` style it prints the standard menu's items, shortcuts and states to stdout); `--preview-settings TAB
/// --preview-snapshot PNG` renders one Settings tab (general, recording, storage, dictation, agents);
/// `--preview-main [--preview-main-select ID] [--preview-main-width PT] [--preview-main-recording ID]`
/// renders the main window (ID stands in for a live session; a seeded `recording` status would be recovered at launch) and logs its toolbar and main menu;
/// `--preview-menu-icon DIR` writes every menu bar icon state at 1x and 2x, light and dark. `--preview-dark` renders in Dark Mode.
/// With `--preview-menu`: `--preview-menu-recording` shows a synthetic recording (mic hearing, call
/// playing at about half level, 12:40 elapsed); `--preview-menu-hover mic|call|live|pill|dictation`
/// starts with that tile hovered, so its details card shows; `--preview-light` forces Light Mode.
@MainActor
enum MenuPreview {
    /// Set only by `--preview-menu-recording`; `MenuRecording.current` falls back to it.
    static var recording: MenuRecording?

    static func startIfRequested(_ args: [String] = CommandLine.arguments) {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let dir = value("--preview-menu-icon") {
            MenuBarIcon.writePreviews(to: URL(fileURLWithPath: dir))
            HSLog("menu-preview").info("Menu icon previews in \(dir)")
            if !args.contains("--preview-menu"), value("--preview-settings") == nil { NSApp.terminate(nil); return }
        }
        if args.contains("--preview-main") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated {
                    let model = MainWindowModel.shared
                    model.previewRecordingID = value("--preview-main-recording")
                    if model.previewRecordingID != nil {
                        // Sample lines so the live pane and its name fields have something to show.
                        LiveModel.shared.update([
                            LiveLine(speaker: "mic-1", stream: .mic, start: 2, end: 6, text: "Morning, Dana, can you hear me?"),
                            LiveLine(speaker: "sys-1", stream: .system, start: 7, end: 12, text: "Loud and clear. Kim is joining late."),
                            LiveLine(speaker: "sys-2", stream: .system, start: 13, end: 19, text: "Sorry, I'm here now."),
                        ])
                    }
                    // `--preview-main-hidden-sidebar`: as if the sidebar was closed last time.
                    if args.contains("--preview-main-hidden-sidebar") { model.columns = .detailOnly }
                    let w = MainWindowController.shared.show()
                    if let width = value("--preview-main-width").flatMap(Double.init) {
                        w.setContentSize(NSSize(width: width, height: w.contentRect(forFrameRect: w.frame).height))
                    }
                    if let id = value("--preview-main-select") { model.select(id) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        MainActor.assumeIsolated {
                            let log = HSLog("menu-preview")
                            log.info("Main window \(Int(w.frame.width))x\(Int(w.frame.height)); toolbar: \(w.toolbar.map { $0.items.map { $0.label.isEmpty ? $0.itemIdentifier.rawValue : $0.label } } ?? [])")
                            for item in NSApp.mainMenu?.items ?? [] {
                                let sub = (item.submenu?.items ?? []).map { $0.isSeparatorItem ? "---" : $0.title + ($0.keyEquivalent.isEmpty ? "" : " ⌘" + $0.keyEquivalent.uppercased()) }
                                log.info("Menu \(item.title): \(sub.joined(separator: " | "))")
                            }
                            log.info("Sidebar groups: \(model.groups.map { "\($0.title) \($0.meetings.count)" })")
                            if let path = value("--preview-snapshot") { MeetingPreview.snapshot(w, to: URL(fileURLWithPath: path), frame: true) }
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
            return
        }
        let view: AnyView
        let title: String
        if args.contains("--preview-menu") {
            if args.contains("--preview-menu-recording") {
                recording = MenuRecording(title: "Weekly design sync", elapsed: 760, micLevel: -22, systemLevel: -30, warnings: [], micActive: true, callActive: true)
            }
            let hover: MenuControl? = switch value("--preview-menu-hover") {
            case "mic": .mic
            case "call": .call
            case "live": .live
            case "pill": .pill
            case "dictation": .dictation
            case "cleanup": .cleanup
            default: nil
            }
            let style = value("--preview-menu-style").flatMap(MenuStyle.init) ?? MenuStyle.current
            if style == .menu {
                // A status-item NSMenu cannot be drawn headless; print its items instead.
                print(StandardMenu.dump(model: AppModel.shared))
                fflush(stdout)
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return
            }
            view = AnyView(MenuContent(model: AppModel.shared, selected: hover).fixedSize())
            title = "Menu preview"
        } else if let tab = value("--preview-settings") {
            let t: SettingsView.Tab = switch tab {
            case "recording": .recording
            case "storage": .storage
            case "dictation": .dictation
            case "agents": .agents
            default: .general
            }
            view = AnyView(SettingsView(initial: t))
            title = "Settings preview"
        } else { return }

        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
                let size = host.fittingSize
                let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
                w.title = title
                w.isReleasedWhenClosed = false
                if args.contains("--preview-dark") { w.appearance = NSAppearance(named: .darkAqua) }
                if args.contains("--preview-light") { w.appearance = NSAppearance(named: .aqua) }
                let container = NSView(frame: NSRect(origin: .zero, size: size))
                host.sizingOptions = []
                host.frame = container.bounds
                host.autoresizingMask = [.width, .height]
                container.addSubview(host)
                w.contentView = container
                w.center()
                w.orderFrontRegardless()
                HSLog("menu-preview").info("\(title) \(Int(size.width))x\(Int(size.height))")
                guard let path = value("--preview-snapshot") else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    MainActor.assumeIsolated {
                        MeetingPreview.snapshot(w, to: URL(fileURLWithPath: path))
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }
}
