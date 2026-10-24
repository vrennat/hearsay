import AppKit
import Foundation
import HearsayCore

/// Debug launch: `--preview-pill [--preview-elapsed SECONDS] [--preview-expanded] [--preview-pill-state nomic]
/// [--preview-snapshot PNG]` shows the pill with a
/// synthetic level and no recording, so it can be looked at and screenshotted. With
/// `--preview-elapsed` the clock is frozen at that value (deterministic screenshots); without, it runs.
/// `--preview-snapshot` renders the panel's own view hierarchy to a PNG after 1.5 s and quits: the
/// agent shell has no Screen Recording permission, so `screencapture` cannot see the screen.
@MainActor
enum PillPreview {
    static func startIfRequested(_ args: [String] = CommandLine.arguments) {
        guard args.contains("--preview-pill") else { return }
        var fixed: TimeInterval?
        if let i = args.firstIndex(of: "--preview-elapsed"), i + 1 < args.count { fixed = TimeInterval(args[i + 1]) }
        let expanded = args.contains("--preview-expanded")
        let started = Date()
        let m = PillModel(levels: synthetic)
        m.title = "Preview: Weekly design sync with a long title"
        m.onStop = { NotchPillController.shared.hide() }
        m.elapsed = fixed ?? 0
        // `--preview-pill-state nomic`: the 10 s mic-silence warning ("No mic" in place of the meter).
        if let i = args.firstIndex(of: "--preview-pill-state"), i + 1 < args.count, args[i + 1] == "nomic" { m.warning = true }
        NotchPillController.shared.show(model: m)
        if expanded { NotchPillController.shared.setExpanded(true) }
        HSLog("pill").info("Preview pill (elapsed \(fixed.map { "\($0)" } ?? "running"), expanded \(expanded))")
        if let i = args.firstIndex(of: "--preview-snapshot"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { NotchPillController.shared.snapshot(to: url) }
                NSApp.terminate(nil)
            }
        }
        guard fixed == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { m.elapsed = Date().timeIntervalSince(started) }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    /// Speech-like: syllable bursts in phrases, with a 1.5 s pause every 6 s (meter rests), plus a
    /// quieter call layer.
    nonisolated static func synthetic() -> (Float, Float) {
        let t = Date().timeIntervalSinceReferenceDate
        let phase = t.truncatingRemainder(dividingBy: 6)
        guard phase < 4.5 else { return (-100, -100) }
        let syllable = 0.5 + 0.5 * sin(t * 2 * .pi * 4.3)
        let phrase = 0.6 + 0.4 * sin(t * 1.3)
        let mic = Float(-50 + 36 * syllable * phrase)
        let sys = Float(-55 + 20 * (0.5 + 0.5 * sin(t * 2 * .pi * 2.1 + 1)))
        return (mic, sys)
    }
}
