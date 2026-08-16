import SwiftUI
import Combine
import ToDoCore
import AppKit

/// The menu bar "what's next" glance — a quick read of what's happening now
/// and what's coming up today, without switching to the main window. Reuses
/// the same `TaskStore` the main window watches, so it's never stale by more
/// than the store's own ~1s poll.
struct MenuBarView: View {
    @ObservedObject var store: TaskStore
    @Environment(\.openWindow) private var openWindow

    /// The glance is a clock as much as a list: "Now" and "in 20 min" are
    /// both functions of the current time, but the view only re-rendered
    /// when `store.tasks` changed — so on a quiet afternoon the countdown
    /// would sit frozen at whatever it read when the last file was written.
    @State private var now = Date()

    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var todayItems: [TaskItem] {
        let today = TaskFile.todayString(now)
        return store.tasks
            .filter { $0.dateString == today && $0.hasTime && !$0.isDone }
            .sorted { ($0.startMinutes ?? 0) < ($1.startMinutes ?? 0) }
    }

    private var nowMinutes: Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    private var currentItem: TaskItem? {
        todayItems.first { item in
            guard let start = item.startMinutes else { return false }
            let end = item.endMinutes ?? (start + 30)
            return start <= nowMinutes && nowMinutes < end
        }
    }

    private var upcomingItems: [TaskItem] {
        todayItems.filter { item in
            guard let start = item.startMinutes else { return false }
            return start > nowMinutes
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Today")
                .font(.headline)

            if currentItem == nil && upcomingItems.isEmpty {
                Text("Nothing left scheduled today.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let current = currentItem {
                glanceRow(current, label: "Now", tint: .aircallAccent)
            }

            if let next = upcomingItems.first {
                glanceRow(next, label: timeUntilLabel(next), tint: .secondary)
            }

            if upcomingItems.count > 1 {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(upcomingItems.dropFirst().prefix(4)) { item in
                        compactRow(item)
                    }
                }
            }

            Divider()

            HStack {
                Button("Open To-Do") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(12)
        .frame(width: 280)
        .onReceive(clock) { now = $0 }
        .onAppear { now = Date() }
    }

    @ViewBuilder
    private func glanceRow(_ item: TaskItem, label: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(tint)
                Text(item.title)
                    .fontWeight(.medium)
                if let start = item.startMinutes {
                    Text(TaskFile.formatMinutesDisplay(start))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            if let link = item.link {
                Link(destination: link) {
                    Image(systemName: "arrow.up.right.circle.fill")
                }
                .help(link.absoluteString)
            }
        }
    }

    private func compactRow(_ item: TaskItem) -> some View {
        HStack(spacing: 6) {
            if let start = item.startMinutes {
                Text(TaskFile.formatMinutesDisplay(start))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text(item.title)
                .font(.caption)
                .lineLimit(1)
            Spacer()
        }
    }

    private func timeUntilLabel(_ item: TaskItem) -> String {
        guard let start = item.startMinutes else { return "" }
        let delta = start - nowMinutes
        if delta <= 0 { return "Starting now" }
        if delta < 60 { return "in \(delta) min" }
        let h = delta / 60
        let m = delta % 60
        return m == 0 ? "in \(h)h" : "in \(h)h \(m)m"
    }
}
