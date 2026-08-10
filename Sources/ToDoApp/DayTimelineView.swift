import SwiftUI

/// The calendar-style day timeline: hour axis on the left, time-blocked
/// tasks/meetings positioned and sized by their start/end on the right.
/// Expands past the working-hours window rather than clipping if something
/// is scheduled earlier or later.
struct DayTimelineView: View {
    let items: [TaskItem] // must all have startMinutes != nil
    let isToday: Bool
    var onTap: (TaskItem) -> Void
    var onToggle: (TaskItem) -> Void

    private let hourHeight: CGFloat = 80
    private let workingStart = 7 * 60  // 7 AM
    private let workingEnd = 19 * 60   // 7 PM
    private let hourLabelWidth: CGFloat = 54

    @State private var now = Date()
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var dayStart: Int {
        let earliest = items.compactMap(\.startMinutes).min() ?? workingStart
        return min(workingStart, (earliest / 60) * 60)
    }

    private var dayEnd: Int {
        let latest = items
            .compactMap { task -> Int? in
                guard let start = task.startMinutes else { return nil }
                return task.endMinutes ?? (start + 30)
            }
            .max() ?? workingEnd
        return max(workingEnd, ((latest + 59) / 60) * 60)
    }

    private var pxPerMinute: CGFloat { hourHeight / 60 }
    private var totalHeight: CGFloat { CGFloat(dayEnd - dayStart) * pxPerMinute }
    private var hourMarks: [Int] { Array(stride(from: dayStart, through: dayEnd, by: 60)) }
    private var placements: [TimelineLayout.Placement] { TimelineLayout.layout(items) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Absolute-positioned (not a VStack of fixed-height rows) so
            // every label sits at *exactly* the same y as its gridline and
            // any block starting at that minute — no implicit-sizing drift
            // between the three.
            ZStack(alignment: .topLeading) {
                ForEach(hourMarks, id: \.self) { minute in
                    Text(TaskFile.formatMinutesDisplay(minute))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: hourLabelWidth, alignment: .leading)
                        .offset(y: CGFloat(minute - dayStart) * pxPerMinute - 6)
                }
            }
            .frame(width: hourLabelWidth, height: totalHeight, alignment: .topLeading)

            ZStack(alignment: .topLeading) {
                ForEach(hourMarks, id: \.self) { minute in
                    Divider()
                        .offset(y: CGFloat(minute - dayStart) * pxPerMinute)
                }

                GeometryReader { geo in
                    ForEach(placements, id: \.task.id) { placement in
                        let columnWidth = geo.size.width / CGFloat(placement.columnCount)
                        let blockWidth = max(columnWidth - 6, 32)
                        let blockHeight = CGFloat(placement.end - placement.start) * pxPerMinute
                        let x = CGFloat(placement.column) * columnWidth
                        let y = CGFloat(placement.start - dayStart) * pxPerMinute

                        TimelineBlock(
                            task: placement.task,
                            onTap: { onTap(placement.task) },
                            onToggle: { onToggle(placement.task) }
                        )
                        .frame(width: blockWidth, height: max(blockHeight, 30))
                        .position(x: x + blockWidth / 2 + 2, y: y + max(blockHeight, 30) / 2)
                    }
                }

                if isToday, let nowMinute = currentMinuteIfInRange {
                    NowLine()
                        .offset(y: CGFloat(nowMinute - dayStart) * pxPerMinute - 4)
                }
            }
            .frame(height: totalHeight)
        }
        .onReceive(timer) { now = $0 }
    }

    private var currentMinuteIfInRange: Int? {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return (dayStart...dayEnd).contains(minute) ? minute : nil
    }
}

private struct NowLine: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Rectangle().fill(Color.red).frame(height: 2)
        }
    }
}

private struct TimelineBlock: View {
    let task: TaskItem
    let onTap: () -> Void
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Tap-to-edit is scoped to just this header+title area — never
            // to the description below — so a link inside the description
            // is never in competition with the edit gesture for a tap.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Button(action: onToggle) {
                        Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)

                    Text(timeRangeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if !task.tags.isEmpty {
                        HStack(spacing: 3) {
                            ForEach(task.tags, id: \.self) { tag in
                                TagPill(text: tag, compact: true)
                            }
                        }
                        .lineLimit(1)
                    }

                    if let link = task.link {
                        Link(destination: link) {
                            Image(systemName: "arrow.up.right.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .help(link.absoluteString)
                    }

                    Button(action: onTap) {
                        Image(systemName: "pencil.circle")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .help("Edit")
                }

                Text(task.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .strikethrough(task.isDone)
                    .lineLimit(2)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)

            if !task.rawBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownText(text: task.rawBody)
                    .font(.caption2)
                    .lineLimit(3)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderColor, lineWidth: 1))
        .opacity(task.isDone ? 0.55 : 1)
    }

    private var background: Color {
        task.kind == .meeting ? Color.aircallGreen.opacity(0.25) : Color.gray.opacity(0.18)
    }
    private var borderColor: Color {
        task.kind == .meeting ? Color.aircallGreen.opacity(0.6) : Color.gray.opacity(0.4)
    }
    private var timeRangeLabel: String {
        guard let start = task.startMinutes else { return "" }
        guard let end = task.endMinutes else { return TaskFile.formatMinutesDisplay(start) }
        return "\(TaskFile.formatMinutesDisplay(start))–\(TaskFile.formatMinutesDisplay(end))"
    }
}
