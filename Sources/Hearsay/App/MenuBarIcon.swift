import AppKit
import SwiftUI

/// Menu bar glyph: a filled opening double quote, the 18 x 18 pt counterpart of
/// `Resources/AppIcon.icon`. A filled outline, not a stroke, so it keeps its weight at 1x. Loaded as
/// vector SVG (`_NSSVGImageRep`), so AppKit rasterises it at the menu bar's scale. See CLAUDE.md "Icons".
///
/// Spec amendment "Menu bar icon": the mark is in the label colour in every state; while recording a
/// small red dot sits at its lower right. The recording image is non-template (so the red survives) and
/// is drawn lazily: AppKit runs the drawing handler with the status item's appearance current, so the
/// glyph is filled with `labelColor` for that appearance, matching what a template image would get.
enum MenuBarState: String, CaseIterable {
    case idle, recording, dictating, processing

    var accessibilityLabel: String {
        switch self {
        case .idle: "Hearsay"
        case .recording: "Hearsay, recording"
        case .dictating: "Hearsay, dictating"
        case .processing: "Hearsay, transcribing"
        }
    }
}

struct MenuBarIcon: View {
    let state: MenuBarState

    var body: some View {
        Image(nsImage: Self.image(state))
            .accessibilityLabel(state.accessibilityLabel)
    }

    /// Opening double quote, Hoefler Text Black, the 18 pt counterpart of `01-mark.svg` in the app icon
    /// (glyph outline exported with Core Text in a 295 x 251 box, scaled to 14 pt wide). One filled
    /// shape, so it keeps its weight at 1x and in the recording image.
    private static let quote = "M 161.7 162.8 Q 161.7 109.6 189.7 69.3 Q 217.7 29.1 267.4 0.4 Q 269.5 -1.0 274.4 2.8 Q 279.3 6.7 281.4 9.5 Q 283.5 12.3 285.9 18.2 Q 288.4 24.2 286.3 24.9 Q 266.0 37.5 247.1 59.5 Q 228.2 81.6 228.2 109.6 Q 228.2 118.0 229.2 121.5 Q 230.3 125.0 233.1 125.0 Q 235.2 125.0 237.6 123.9 Q 240.1 122.9 243.6 122.9 Q 263.9 122.9 279.3 137.2 Q 294.7 151.6 294.7 182.4 Q 294.7 208.3 276.8 229.6 Q 259.0 251.0 231.0 251.0 Q 199.5 251.0 180.6 225.8 Q 161.7 200.6 161.7 162.8 Z M 0.0 162.8 Q 0.0 109.6 28.0 69.3 Q 56.0 29.1 105.7 0.4 Q 107.8 -1.0 112.7 2.8 Q 117.6 6.7 119.7 9.5 Q 121.8 12.3 124.2 18.2 Q 126.7 24.2 124.6 24.9 Q 104.3 37.5 85.4 59.5 Q 66.5 81.6 66.5 109.6 Q 66.5 118.0 67.5 121.5 Q 68.6 125.0 71.4 125.0 Q 73.5 125.0 76.0 123.9 Q 78.4 122.9 81.9 122.9 Q 102.2 122.9 117.6 137.2 Q 133.0 151.6 133.0 182.4 Q 133.0 208.3 115.1 229.6 Q 97.3 251.0 69.3 251.0 Q 37.8 251.0 18.9 225.8 Q 0.0 200.6 0.0 162.8 Z"
    private static let quoteTransform = "translate(2 3.04) scale(0.04751)"

    /// SVG source for one state, without the recording dot (drawn separately so it can be red).
    /// Dictating and processing only dim the mark (the menu's status line names the state); no extra
    /// marks at menu bar size. Tanner found a glyph + arcs plus the dot unreadable at 18 pt.
    static func svg(_ state: MenuBarState) -> String {
        let opacity: Double
        switch state {
        case .idle, .recording: opacity = 1
        case .dictating: opacity = 0.55
        case .processing: opacity = 0.7
        }
        return #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 18 18" width="18" height="18"><path fill-rule="nonzero" transform="\#(quoteTransform)" d="\#(quote)" fill="black" fill-opacity="\#(opacity)"/></svg>"#
    }

    static func image(_ state: MenuBarState) -> NSImage {
        let glyph = NSImage(data: Data(svg(state).utf8)) ?? NSImage(size: NSSize(width: 18, height: 18))
        glyph.size = NSSize(width: 18, height: 18)
        guard state == .recording else {
            glyph.isTemplate = true
            glyph.accessibilityDescription = state.accessibilityLabel
            return glyph
        }
        let image = NSImage(size: glyph.size, flipped: false) { rect in
            glyph.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            // Lower right on the half-point grid, over the tail of the second mark.
            let d = NSRect(x: 13, y: 1, width: 4.5, height: 4.5)
            // A clear ring keeps the dot legible where it overlaps the mark.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: d.insetBy(dx: -1, dy: -1)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: d).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = state.accessibilityLabel
        return image
    }

    /// Writes every state at 1x and 2x on light and dark backgrounds (`--preview-menu-icon DIR`).
    /// Template images are tinted with `labelColor` here, as the menu bar would.
    static func writePreviews(to dir: URL) {
        for state in MenuBarState.allCases {
            for (appearanceName, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                for scale in [1, 2] {
                    NSAppearance(named: appearanceName)!.performAsCurrentDrawingAppearance {
                        let img = image(state)
                        let side = 18 * scale
                        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                        rep.size = NSSize(width: 18, height: 18)
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                        let r = NSRect(x: 0, y: 0, width: 18, height: 18)
                        NSColor.windowBackgroundColor.setFill()
                        r.fill()
                        if img.isTemplate {
                            let tinted = NSImage(size: r.size, flipped: false) { rr in
                                img.draw(in: rr)
                                NSColor.labelColor.set()
                                rr.fill(using: .sourceAtop)
                                return true
                            }
                            tinted.draw(in: r)
                        } else {
                            img.draw(in: r)
                        }
                        NSGraphicsContext.restoreGraphicsState()
                        let url = dir.appendingPathComponent("menu-icon-\(state.rawValue)-\(suffix)@\(scale)x.png")
                        try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    }
                }
            }
        }
    }
}
