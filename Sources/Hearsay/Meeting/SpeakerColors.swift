import AppKit
import SwiftUI

/// One muted colour per speaker, shared by the transcript names, the timeline and the inspector.
/// Colours follow the inspector's order (most talk time first), so the biggest talker is always the
/// first colour. Each has a darker light-mode and a lighter dark-mode variant for contrast on the
/// window background; none is the accent colour, which marks the playing line.
enum SpeakerColors {
    private static let pairs: [(light: UInt32, dark: UInt32)] = [
        (0x2F6FB3, 0x82B4E6),  // sky
        (0xB0603E, 0xE6A084),  // clay
        (0x4E8A5B, 0x8FC79C),  // sage
        (0x8E7420, 0xD9BC62),  // ochre
        (0x7A5BA8, 0xB7A1DE),  // lavender
        (0x2F8784, 0x7FCBC5),  // teal
        (0xA64D6E, 0xDE92AF),  // rose
        (0x5E6B7A, 0xA6B2C0),  // slate
    ]

    private static let colors: [Color] = pairs.map { p in
        Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let v = dark ? p.dark : p.light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }

    static func color(at index: Int) -> Color { colors[index % colors.count] }
}

extension MeetingModel {
    /// The speaker's colour; a speaker missing from the inspector list (a parsed `live.md` name) is slate.
    func color(for speaker: String) -> Color {
        SpeakerColors.color(at: speakers.firstIndex { $0.id == speaker } ?? 7)
    }
}

extension MeetingModel {
    /// The speaker's fraction of everyone's talk time, 0 to 1.
    func talkShare(_ speaker: String) -> Double {
        let total = speakers.reduce(0) { $0 + $1.talkSeconds }
        guard total > 0 else { return 0 }
        return (speakers.first { $0.id == speaker }?.talkSeconds ?? 0) / total
    }
}
