import HearsayCore
import SwiftUI

/// Who spoke when: one lane per speaker (inspector order), a bar for each transcript line, and the
/// playhead. Clicking or dragging seeks. Lanes are capped so a meeting with many voices stays compact.
struct SpeakerTimeline: View {
    let model: MeetingModel
    static let maxLanes = 6
    private static let laneHeight: CGFloat = 12
    private static let nameWidth: CGFloat = 72

    private var lanes: [MeetingModel.SpeakerRow] { Array(model.speakers.prefix(Self.maxLanes)) }

    private var span: Double {
        max(model.player?.duration ?? 0, model.meeting.duration ?? 0, model.lines.lines.last?.end ?? 0, 1)
    }

    var body: some View {
        let lanes = lanes
        if lanes.isEmpty || model.lines.lines.isEmpty {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(lanes) { s in
                        Text(model.displayName(s.id)).font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary).lineLimit(1)
                            .frame(width: Self.nameWidth, height: Self.laneHeight, alignment: .trailing)
                    }
                }
                lanesCanvas(lanes)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Speaker timeline")
            .accessibilityValue(lanes.map { "\(model.displayName($0.id)) \(ElapsedLabel.spoken($0.talkSeconds))" }.joined(separator: ", "))
        }
    }

    private func lanesCanvas(_ lanes: [MeetingModel.SpeakerRow]) -> some View {
        let index = Dictionary(uniqueKeysWithValues: lanes.enumerated().map { ($1.id, $0) })
        let span = span
        let height = CGFloat(lanes.count) * Self.laneHeight + CGFloat(lanes.count - 1) * 4
        return GeometryReader { geo in
            let w = geo.size.width
            Canvas { ctx, size in
                for (i, _) in lanes.enumerated() {
                    let y = CGFloat(i) * (Self.laneHeight + 4)
                    ctx.fill(Path(roundedRect: CGRect(x: 0, y: y, width: size.width, height: Self.laneHeight), cornerRadius: 3),
                             with: .style(.quaternary))
                }
                for line in model.lines.lines {
                    guard let i = index[line.speaker] else { continue }
                    let x0 = CGFloat(line.start / span) * size.width
                    let x1 = max(x0 + 2, CGFloat(line.end / span) * size.width)
                    let y = CGFloat(i) * (Self.laneHeight + 4)
                    ctx.fill(Path(roundedRect: CGRect(x: x0, y: y, width: x1 - x0, height: Self.laneHeight), cornerRadius: 2),
                             with: .color(model.color(for: line.speaker)))
                }
                if let p = model.player {
                    let x = CGFloat(p.time / span) * size.width
                    ctx.fill(Path(CGRect(x: x - 0.75, y: -2, width: 1.5, height: size.height + 4)), with: .style(.primary))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard let p = model.player else { return }
                p.seek(to: Double(max(0, min(g.location.x, w)) / w) * span)
            })
            .help(model.player == nil ? "Who spoke when" : "Who spoke when. Click to play from that point.")
        }
        .frame(height: height)
    }
}
