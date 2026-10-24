import AppKit
import Observation
import ApplicationServices
@preconcurrency import AVFoundation
import Foundation
import HearsayCore

/// The dictation hotkey key (setting `dictationKey`).
enum DictationKey: String, CaseIterable {
    case rightOption, rightCommand, fn

    var title: String {
        switch self { case .rightOption: "Right Option"; case .rightCommand: "Right Command"; case .fn: "Fn" }
    }
    var keyCode: UInt16 {
        switch self { case .rightOption: 61; case .rightCommand: 54; case .fn: 63 }
    }
    /// Whether the key is down in a `flagsChanged` event. Right Option / Right Command use the
    /// device-dependent bits (NX_DEVICERALTKEYMASK, NX_DEVICERCMDKEYMASK) so the left key does not count.
    func isDown(_ flags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .rightOption: flags.rawValue & 0x40 != 0
        case .rightCommand: flags.rawValue & 0x10 != 0
        case .fn: flags.contains(.function)
        }
    }

    static var current: DictationKey { DictationKey(rawValue: Prefs.defaults.string(forKey: Prefs.dictationKey) ?? "") ?? .rightOption }
}

/// Hold-to-talk dictation (spec, Dictation). Key rules live in `DictationKeyMachine`; this class owns
/// the monitors, the separate microphone, the bubble and the paste. Saves nothing; logs lengths and
/// timings only. Off for test instances.
@MainActor @Observable
final class DictationController {
    static let shared = DictationController()
    private let log = HSLog("dictation")
    private let transcriber = DictationTranscriber()
    private var machine = DictationKeyMachine()
    private var monitors: [Any] = []
    private var trustPoll: Timer?
    private var trusted = false
    private var key = DictationKey.rightOption
    private var capture: DictationCapture?
    private var startedAt = Date()
    private var prepared = false

    /// Holding the key and capturing; the menu bar icon observes this.
    var isActive: Bool { capture != nil }

    private var enabled: Bool { Prefs.dictationOn && !AppModel.shared.options.isTestInstance }

    /// At launch and whenever the Dictation settings change.
    func settingsChanged() {
        removeMonitors()
        trustPoll?.invalidate(); trustPoll = nil
        guard enabled else {
            if capture != nil { cancel(reason: "dictation turned off") }
            return
        }
        key = DictationKey.current
        trusted = AXIsProcessTrusted()
        addMonitors()
        if !trusted {
            // Global key monitors receive nothing until Accessibility is granted; re-add them once it is.
            let t = Timer(timeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated { DictationController.shared.checkTrust() }
            }
            RunLoop.main.add(t, forMode: .common)
            trustPoll = t
        }
        if !prepared {
            prepared = true
            Task { [transcriber, log] in
                do { try await transcriber.prepare() } catch { log.error("Dictation models did not load: \(error)") }
            }
        }
        log.info("Dictation on: key \(key.rawValue), accessibility \(trusted ? "granted" : "not granted")")
    }

    private func checkTrust() {
        guard AXIsProcessTrusted() else { return }
        log.info("Accessibility granted; re-adding key monitors")
        settingsChanged()
    }

    private func addMonitors() {
        let handler: (NSEvent) -> Void = { event in
            MainActor.assumeIsolated { DictationController.shared.handle(event) }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { handler($0); return $0 }) {
            monitors.append(l)
        }
    }

    private func removeMonitors() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        machine.reset()
    }

    private func handle(_ event: NSEvent) {
        let e: DictationKeyMachine.Event
        switch event.type {
        case .flagsChanged where event.keyCode == key.keyCode:
            e = key.isDown(event.modifierFlags) ? .keyDown(at: event.timestamp) : .keyUp(at: event.timestamp)
        case .flagsChanged:
            // Another modifier: only its press counts as "another key".
            guard Self.modifierPressed(event) else { return }
            e = .otherKey(escape: false)
        case .keyDown:
            e = .otherKey(escape: event.keyCode == 53)
        default:
            return
        }
        switch machine.handle(e) {
        case .none: break
        case .start: start()
        case .finish: finish()
        case .cancel: cancel(reason: "another key")
        }
    }

    private static func modifierPressed(_ event: NSEvent) -> Bool {
        let f = event.modifierFlags
        switch event.keyCode {
        case 54, 55: return f.contains(.command)
        case 56, 60: return f.contains(.shift)
        case 58, 61: return f.contains(.option)
        case 59, 62: return f.contains(.control)
        case 63: return f.contains(.function)
        case 57: return f.contains(.capsLock)
        default: return false
        }
    }

    // MARK: Session

    private func start() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) != .denied else {
            DictationBubble.shared.show()
            DictationBubble.shared.finish(note: "Microphone access is off for Hearsay.", after: 2.5)
            machine.reset()
            return
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            machine.reset()
            return
        }
        startedAt = Date()
        DictationBubble.shared.show()
        let c = DictationCapture()
        capture = c
        let transcriber = transcriber
        Task {
            await transcriber.configure(glossary: Glossary.load(root: AppModel.shared.store.root), cleanup: Prefs.cleanupOn)
            try? await transcriber.startStreaming { text in
                Task { @MainActor in DictationBubble.shared.update(text) }
            }
        }
        do {
            try c.start { samples in
                Task { try? await transcriber.appendStreaming(samples) }
            }
            log.info("Dictation started")
        } catch {
            log.error("Dictation mic did not start: \(error)")
            capture = nil
            machine.reset()
            DictationBubble.shared.finish(note: "Could not open the microphone.", after: 2.5)
        }
    }

    private func cancel(reason: String) {
        guard let c = capture else { return }
        capture = nil
        let clip = c.stop()
        Task { [transcriber] in await transcriber.endStreaming() }
        DictationBubble.shared.finish()
        log.info("Dictation cancelled (\(reason)) after \(String(format: "%.2f", Double(clip.count) / 16_000)) s")
    }

    private func finish() {
        guard let c = capture else { return }
        capture = nil
        let clip = c.stop()
        let held = Date().timeIntervalSince(startedAt)
        Task { [transcriber, log] in
            await transcriber.endStreaming()
            do {
                let r = try await transcriber.transcribe(clip)
                log.info("Dictation held \(String(format: "%.2f", held)) s, clip \(String(format: "%.2f", r.clipSeconds)) s, \(r.text.count) chars in \(String(format: "%.3f", r.seconds)) s")
                await MainActor.run { Paster.deliver(r.text) }
            } catch {
                log.error("Dictation transcription failed: \(error)")
                await MainActor.run { DictationBubble.shared.finish(note: "Dictation failed.", after: 2.5) }
            }
        }
    }

    static func openAccessibilitySettings() {
        // Also registers Hearsay in the list so the user only has to flip the switch.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Puts dictated text into the focused app: ⌘V through `CGEvent`, then the previous clipboard back
/// after 0.5 s. Both writes are `currentHostOnly` so Universal Clipboard never sends them to another
/// device. A password manager's item (`org.nspasteboard.ConcealedType`) is never restored.
@MainActor
enum Paster {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let pasteableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    static func deliver(_ text: String) {
        let bubble = DictationBubble.shared
        guard !text.isEmpty else { bubble.finish(); return }
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        write(text, to: pb)
        guard AXIsProcessTrusted() else {
            bubble.update(text)
            bubble.finish(note: "Copied. Allow Accessibility in Settings to paste.", after: 2.5)
            return
        }
        let target = focusedAcceptsText()
        postCommandV()
        if !target {
            bubble.finish(note: "Pasted; also left on the clipboard (no text field focused).", after: 2.5)
            return
        }
        bubble.finish()
        let ours = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                guard pb.changeCount == ours else { return }  // something else was copied since
                if let saved, !saved.isEmpty, !saved.contains(where: { $0.types.contains(concealed) }) {
                    pb.prepareForNewContents(with: .currentHostOnly)
                    pb.writeObjects(saved)
                } else {
                    pb.clearContents()
                }
            }
        }
    }

    private static func write(_ text: String, to pb: NSPasteboard) {
        pb.prepareForNewContents(with: .currentHostOnly)
        pb.setString(text, forType: .string)
    }

    /// Copies of the current items (the originals belong to the pasteboard and go stale on clear).
    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem]? {
        pb.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
    }

    /// The focused element is a text field, text area, combo box or search field, or its value is settable.
    static func focusedAcceptsText() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return false }
        let element = el as! AXUIElement  // CFTypeID checked above
        var role: CFTypeRef?, subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if let r = role as? String, pasteableRoles.contains(r) { return true }
        if let s = subrole as? String, pasteableRoles.contains(s) { return true }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    private static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
