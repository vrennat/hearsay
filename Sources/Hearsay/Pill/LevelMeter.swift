import Foundation
import SwiftUI

/// Bar physics for the pill's level meter (spec amendment: 12-16 thin bars that spring up and ease
/// down, neighbours following the loudest, a gradient that warms with level, a resting shimmer at
/// silence). All state lives in fixed-size arrays allocated once; `step` and `draw` allocate nothing of
/// their own per frame.
final class MeterState {
    static let barCount = 14
    /// Returns (mic, system) dBFS; the floor (-100) once buffers stop for 0.3 s.
    var levels: () -> (Float, Float)
    private var mic = [Double](repeating: 0, count: barCount)
    private var sys = [Double](repeating: 0, count: barCount)
    private var shape = [Double](repeating: 0, count: barCount)
    private var last: TimeInterval = 0

    init(levels: @escaping () -> (Float, Float)) {
        self.levels = levels
        let mid = Double(Self.barCount - 1) / 2
        for i in 0..<Self.barCount {
            let x = (Double(i) - mid) / mid  // -1...1
            shape[i] = 0.5 + 0.5 * exp(-2.2 * x * x)  // taller in the middle
        }
    }

    /// dBFS to 0...1: -60 dBFS (quiet room) to -12 dBFS (loud speech).
    static func norm(_ db: Float) -> Double { min(1, max(0, (Double(db) + 60) / 48)) }

    /// Reduce Motion: bars sit at the level (no wobble, no spread, no shimmer).
    var reduceMotion = false
    /// The last mic level, 0...1, for the accessibility value.
    private(set) var micLevel: Double = 0

    func step(_ t: TimeInterval) {
        let dt = last == 0 ? 1.0 / 60 : min(0.1, max(0, t - last))
        last = t
        let (m, s) = levels()
        micLevel = Self.norm(m)
        if reduceMotion {
            for i in 0..<Self.barCount {
                mic[i] = Self.norm(m) * shape[i]
                sys[i] = Self.norm(s) * shape[i]
            }
            return
        }
        advance(&mic, level: Self.norm(m), t: t, dt: dt, seed: 0)
        advance(&sys, level: Self.norm(s), t: t, dt: dt, seed: 3.1)
    }

    private func advance(_ bars: inout [Double], level: Double, t: TimeInterval, dt: Double, seed: Double) {
        let attack = 1 - exp(-dt * 38)   // ~26 ms
        let release = 1 - exp(-dt * 5.5) // ~180 ms
        for i in 0..<Self.barCount {
            let d = Double(i)
            let wobble = 0.7 + 0.3 * sin(t * (6.1 + d * 0.83) + d * 1.9 + seed)
            let target = level * shape[i] * wobble
            bars[i] += (target - bars[i]) * (target > bars[i] ? attack : release)
        }
        // Spread: neighbours follow the loudest bar, both directions.
        for i in 1..<Self.barCount { bars[i] = max(bars[i], bars[i - 1] * 0.8) }
        for i in stride(from: Self.barCount - 2, through: 0, by: -1) { bars[i] = max(bars[i], bars[i + 1] * 0.8) }
    }

    func draw(_ ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let n = CGFloat(Self.barCount)
        let gap: CGFloat = 1.6
        let w = max(1.5, (size.width - gap * (n - 1)) / n)
        let maxH = size.height
        let midY = size.height / 2
        for i in 0..<Self.barCount {
            let x = CGFloat(i) * (w + gap)
            // Resting shimmer: a slow travelling ripple, never a flat dead line.
            let rest = reduceMotion ? 0.12 : 0.10 + 0.06 * (0.5 + 0.5 * sin(t * 2.4 - Double(i) * 0.62))
            // Call audio: a wider, faint layer behind.
            let hs = CGFloat(max(rest, sys[i])) * maxH
            ctx.fill(Path(roundedRect: CGRect(x: x - 0.6, y: midY - hs / 2, width: w + 1.2, height: hs), cornerRadius: (w + 1.2) / 2),
                     with: .color(Color(red: 0.55, green: 0.6, blue: 1.0, opacity: 0.28)))
            let v = max(rest, mic[i])
            let h = CGFloat(v) * maxH
            ctx.fill(Path(roundedRect: CGRect(x: x, y: midY - h / 2, width: w, height: h), cornerRadius: w / 2),
                     with: .color(Self.heat(v)))
        }
    }

    /// Cool teal at rest, amber in speech, coral-red when loud.
    static func heat(_ v: Double) -> Color {
        let x = min(1, max(0, v))
        if x < 0.5 {
            let k = x / 0.5
            return Color(red: 0.30 + 0.70 * k, green: 0.85 - 0.05 * k, blue: 0.85 - 0.60 * k)
        }
        let k = (x - 0.5) / 0.5
        return Color(red: 1.0, green: 0.80 - 0.45 * k, blue: 0.25 + 0.05 * k)
    }

    /// Words for VoiceOver; the bars are colour and height only.
    static func describe(_ v: Double) -> String {
        switch v {
        case ..<0.05: "Silent"
        case ..<0.35: "Quiet"
        case ..<0.75: "Speaking"
        default: "Loud"
        }
    }
}

struct LevelMeter: View {
    let state: MeterState
    /// False stops the timeline: no frames, no CPU.
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Reduce Motion: four steady updates a second instead of a spring animation at display rate.
        TimelineView(reduceMotion ? .animation(minimumInterval: 0.25, paused: !active)
                                  : .animation(minimumInterval: nil, paused: !active)) { tl in
            Canvas(rendersAsynchronously: false) { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                state.reduceMotion = reduceMotion
                state.step(t)
                state.draw(&ctx, size: size, t: t)
            }
            .accessibilityElement()
            .accessibilityLabel("Microphone level")
            .accessibilityValue(MeterState.describe(state.micLevel))
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
