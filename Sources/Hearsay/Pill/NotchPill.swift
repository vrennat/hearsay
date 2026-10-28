import AppKit
import HearsayCore
import Observation
import SwiftUI

/// What the pill shows. The controller writes it; the view reads it.
@MainActor @Observable
final class PillModel {
    var elapsed: TimeInterval = 0
    var title = ""
    var warning = false
    var expanded = false
    var active = true
    /// "Meeting over?" reason while the end prompt is up; the pill stays expanded until it is answered.
    var endPrompt: String?
    /// Recording paused from the pill: the meter rests and the elapsed label says Paused.
    var paused = false
    @ObservationIgnored var onStop: () -> Void = {}
    @ObservationIgnored var onKeepGoing: () -> Void = {}
    @ObservationIgnored var onPause: () -> Void = {}
    @ObservationIgnored var onHover: (Bool) -> Void = { _ in }
    @ObservationIgnored let meter: MeterState

    init(levels: @escaping () -> (Float, Float)) { meter = MeterState(levels: levels) }
}

/// Geometry of the pill: around the notch, or hanging from the middle of the menu bar without one.
struct PillGeometry: Equatable {
    /// Left of the notch: elapsed (`m:ss`) and meter. Grows to `longLeftWidth` at the hour mark.
    static let leftWidth: CGFloat = 116
    static let longLeftWidth: CGFloat = 140
    static let rightPad: CGFloat = 10
    static let rowHeight: CGFloat = 28

    var collapsed: NSRect
    var expanded: NSRect
    /// Height of the top band (notch or menu bar) that holds elapsed + meter.
    var bandHeight: CGFloat
    /// Width of the area to the left of the notch where elapsed + meter sit.
    var contentWidth: CGFloat
    var hasNotch: Bool

    /// `longElapsed`: the meeting has passed an hour, so the pill reserves `h:mm:ss`.
    @MainActor
    static func make(for screen: NSScreen, longElapsed: Bool = false) -> PillGeometry {
        let f = screen.frame
        let inset = screen.safeAreaInsets.top
        if inset > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            // Widths only, so it works whether the areas are reported in screen or global coordinates.
            let notchMinX = f.minX + l.width
            let notchMaxX = f.maxX - r.width
            let left = longElapsed ? longLeftWidth : leftWidth
            let x = notchMinX - left
            let w = left + (notchMaxX - notchMinX) + rightPad
            let c = NSRect(x: x, y: f.maxY - inset, width: w, height: inset)
            let e = NSRect(x: x, y: f.maxY - inset - rowHeight, width: w, height: inset + rowHeight)
            return PillGeometry(collapsed: c, expanded: e, bandHeight: inset, contentWidth: left, hasNotch: true)
        }
        let bar = max(NSStatusBar.system.thickness, f.maxY - screen.visibleFrame.maxY)
        // Sized to the elapsed label + meter so nothing floats loose; the expanded row grows outward
        // from the same centre.
        let w: CGFloat = longElapsed ? 160 : 136
        let c = NSRect(x: f.midX - w / 2, y: f.maxY - bar, width: w, height: bar)
        // Wide enough for the "Meeting over?" row: label, Keep going and Stop.
        let e = NSRect(x: f.midX - w / 2 - 76, y: f.maxY - bar - rowHeight, width: w + 152, height: bar + rowHeight)
        return PillGeometry(collapsed: c, expanded: e, bandHeight: bar, contentWidth: w, hasNotch: false)
    }
}

/// Non-activating so clicking Stop never steals focus from the call app.
final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel. The SwiftUI hosting view sits inside a plain container view: as the content view it
/// kept resizing the panel until AppKit threw a layout-loop exception (spec). `sizingOptions = []` keeps
/// the hosting view from publishing size constraints at all; the controller alone sets the frame.
@MainActor
final class NotchPillController {
    static let shared = NotchPillController()
    private let log = HSLog("pill")
    private var panel: PillPanel?
    private(set) var model: PillModel?
    private var geometry: PillGeometry?
    private var screenObserver: NSObjectProtocol?

    func show(model: PillModel) {
        hide()
        self.model = model
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let g = PillGeometry.make(for: screen, longElapsed: model.elapsed >= 3600)
        geometry = g
        model.onHover = { [weak self] h in self?.setExpanded(h) }
        let p = PillPanel(contentRect: g.collapsed, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.setAccessibilityLabel("Hearsay recording status")
        let container = NSView(frame: NSRect(origin: .zero, size: g.collapsed.size))
        container.autoresizingMask = [.width, .height]
        let host = NSHostingView(rootView: NotchPillView(model: model, geometry: g))
        host.sizingOptions = []
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        p.contentView = container
        p.setFrame(g.collapsed, display: true)
        p.orderFrontRegardless()
        panel = p
        log.info("Pill shown \(g.hasNotch ? "around the notch" : "under the menu bar") at \(NSStringFromRect(g.collapsed)) on \(screen.localizedName)")
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let m = self.model else { return }
                self.show(model: m)
            }
        }
        WindowInventory.log("pill shown")
    }

    /// Rebuilds the panel at the hour mark so the no-notch pill grows to fit `h:mm:ss`.
    func relayout() {
        guard let model, let geometry, !geometry.hasNotch else { return }
        show(model: model)
    }

    func setExpanded(_ on: Bool) {
        guard let panel, let g = geometry, let model, model.expanded != on else { return }
        // Hovering away must not hide an unanswered "Meeting over?".
        if !on, model.endPrompt != nil { return }
        model.expanded = on
        // Reduce Motion: jump to the new size instead of growing.
        guard !Announce.reduceMotion else {
            panel.setFrame(on ? g.expanded : g.collapsed, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().setFrame(on ? g.expanded : g.collapsed, display: true)
        }
    }

    /// Renders the live panel's view hierarchy (what is on screen, at the backing scale) to a PNG and
    /// logs the panel size.
    func snapshot(to url: URL) {
        guard let view = panel?.contentView, let host = view.subviews.first,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            log.info("Pill snapshot \(url.path): panel \(NSStringFromRect(panel?.frame ?? .zero)), \(rep.pixelsWide)x\(rep.pixelsHigh) px, elapsed \(MenuContent.elapsed(model?.elapsed ?? 0))")
        } catch { log.error("Pill snapshot failed: \(error)") }
    }

    func hide() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        model?.active = false
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        model = nil
    }
}

struct NotchPillView: View {
    let model: PillModel
    let geometry: PillGeometry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !geometry.hasNotch { Spacer(minLength: 0) }
                band.frame(width: geometry.contentWidth, height: geometry.bandHeight)
                Spacer(minLength: 0)
            }
            if model.expanded {
                HStack(spacing: 10) {
                    if let reason = model.endPrompt {
                        Text("Meeting over?").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            .lineLimit(1).fixedSize()
                            .help(reason)
                            .accessibilityLabel("Meeting over? \(reason)")
                        Spacer(minLength: 4)
                        Button(action: model.onKeepGoing) {
                            Text("Keep going").font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .help("Keep recording")
                    } else {
                        Text(model.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1).truncationMode(.tail)
                            .accessibilityLabel("Meeting: \(model.title)")
                        Spacer(minLength: 4)
                    }
                    if model.endPrompt == nil {
                        Button(action: model.onPause) {
                            Image(systemName: model.paused ? "play.fill" : "pause.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 26, height: 20)
                                .background(Color.white.opacity(0.16), in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(model.paused ? "Resume Recording" : "Pause Recording")
                        .help(model.paused ? "Resume recording" : "Pause recording: nothing is saved or transcribed until you resume, and the pause is cut out of the recording. macOS still shows the mic as in use.")
                    }
                    Button(action: model.onStop) {
                        Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Color.white.opacity(0.16), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop Recording")
                    .help("Stop recording and transcribe the meeting")
                }
                .padding(.horizontal, 14)
                .frame(height: PillGeometry.rowHeight)
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { surface }
        .contentShape(PillShape(radius: 11))
        .onHover { model.onHover($0) }
        .onChange(of: model.elapsed >= 3600) { NotchPillController.shared.relayout() }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hearsay recording")
    }

    /// Around a notch: pure black, because the pill continues the notch hardware (like the Dynamic
    /// Island). Without a notch it floats under the menu bar over arbitrary wallpaper, which is the
    /// floating-control case Liquid Glass is for; the 35 % black tint is the HIG's dimming layer for
    /// bright backgrounds, so the white text and meter stay legible. Under Reduce Transparency the
    /// system renders the glass opaque.
    @ViewBuilder private var surface: some View {
        if geometry.hasNotch {
            PillShape(radius: 11).fill(Color.black)
        } else {
            Color.clear.glassEffect(.regular.tint(.black.opacity(0.35)), in: PillShape(radius: 11))
        }
    }

    private var band: some View {
        HStack(spacing: 10) {
            ElapsedLabel(elapsed: model.elapsed, warning: model.warning, reserveHours: false)
            // Colour is never the only signal: with no mic audio the meter gives way to a symbol and text.
            Group {
                if model.paused {
                    Label("Paused", systemImage: "pause.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1).fixedSize()
                        .accessibilityLabel("Recording paused")
                } else if model.warning {
                    Label("No mic", systemImage: "mic.slash.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.orange)
                        .lineLimit(1).fixedSize()
                        .accessibilityLabel("No microphone audio")
                } else {
                    LevelMeter(state: model.meter, active: model.active)
                }
            }
            .frame(width: 46, height: max(10, geometry.bandHeight * 0.48))
        }
        .padding(.leading, geometry.hasNotch ? 12 : 0)
        .padding(.trailing, geometry.hasNotch ? 6 : 0)
        .frame(maxWidth: .infinity, alignment: geometry.hasNotch ? .leading : .center)
        .help(model.warning ? "Recording, but no mic audio for 10 seconds" : "Recording. Hover to show the title and Stop.")
    }
}

/// Never wraps (spec amendment): monospaced digits, one line, fixed size, and the width of the longest
/// form (`h:mm:ss`, measured from "88:88:88") reserved up front so the pill never changes width.
struct ElapsedLabel: View {
    let elapsed: TimeInterval
    let warning: Bool
    /// Reserve the `h:mm:ss` width from the start. Off for the pill, which grows once at the hour
    /// mark instead (`NotchPillController.relayout`).
    var reserveHours = true

    var body: some View {
        Text(verbatim: reserveHours || elapsed >= 3600 ? "88:88:88" : "88:88")
            .font(Self.font).monospacedDigit().lineLimit(1).fixedSize()
            .hidden()
            .overlay(alignment: .leading) {
                Text(verbatim: MenuContent.elapsed(elapsed))
                    .font(Self.font).monospacedDigit().lineLimit(1).fixedSize()
                    .foregroundStyle(warning ? Color.orange : Color.white)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Elapsed")
            .accessibilityValue(Self.spoken(elapsed))
            .accessibilityAddTraits(.updatesFrequently)
    }

    static let font = Font.system(size: 13, weight: .semibold)

    /// "12 minutes, 40 seconds" rather than "12:40", which VoiceOver may read as a time of day.
    static func spoken(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.allowedUnits = t >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        return f.string(from: max(0, t.rounded(.down))) ?? MenuContent.elapsed(t)
    }
}

/// Flat top (flush with the screen edge), rounded bottom corners, like the notch itself.
struct PillShape: Shape {
    let radius: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY), control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius), control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
