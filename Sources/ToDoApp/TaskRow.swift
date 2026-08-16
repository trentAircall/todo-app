import SwiftUI
import ToDoCore

/// The single row style used everywhere a task or meeting is listed —
/// Schedule, Unscheduled, and Overdue all share this. Flat and simple on
/// purpose: no positioning math, no truncation-prone pills, just a time
/// label (when there is one) and a plain overlap flag when two things
/// double-book each other.
struct TaskRow: View {
    let task: TaskItem
    var timeLabel: String? = nil
    var isOverlapping: Bool = false
    var dateLabel: String? = nil
    var dateLabelTint: Color = .red
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isDone ? .green : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                // Tap-to-edit is scoped to just this title/badges area —
                // never the description below — so a link inside the
                // description is never in competition with the edit
                // gesture for a tap.
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let timeLabel {
                            Text(timeLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Text(task.title)
                            .strikethrough(task.isDone)
                            .foregroundStyle(task.isDone ? .secondary : .primary)
                    }

                    if isOverlapping || dateLabel != nil || !task.tags.isEmpty {
                        HStack(spacing: 4) {
                            if isOverlapping {
                                Label("Overlaps another item", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            if let dateLabel {
                                TagPill(text: dateLabel, tint: dateLabelTint)
                            }
                            ForEach(task.tags, id: \.self) { tag in
                                TagPill(text: tag)
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)

                // `bodyPreview`, not `rawBody`: an appended "## Enrichment
                // log" grows without bound and would push the actual prep
                // notes out of these three lines.
                if !task.bodyPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    MarkdownText(text: task.bodyPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: 8)

            if let link = task.link {
                Link(destination: link) {
                    Image(systemName: "arrow.up.right.circle.fill")
                }
                .buttonStyle(.plain)
                .help(link.absoluteString)
            }

            Button(action: onTap) {
                Image(systemName: "pencil.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Edit")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(task.isDone ? 0.6 : 1)
    }

    private var rowBackground: Color {
        if isOverlapping { return Color.orange.opacity(0.12) }
        if task.kind == .meeting { return Color.aircallGreen.opacity(0.16) }
        return Color.clear
    }
}
