import SwiftUI

/// The day run-sheet: a timeline of scheduled tasks/meetings plus an
/// unscheduled to-do list underneath, for one day at a time.
struct ContentView: View {
    @StateObject private var store = TaskStore()
    @State private var selectedDate = Date()
    @State private var quickAddText = ""
    @State private var editorTarget: EditorTarget?

    enum EditorTarget: Identifiable {
        case new
        case edit(TaskItem)
        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let task): return task.id.path
            }
        }
    }

    private var selectedDateString: String { TaskFile.dateOnlyFormatter.string(from: selectedDate) }
    private var isToday: Bool { selectedDateString == TaskFile.todayString() }

    private var itemsForDay: [TaskItem] {
        store.tasks.filter { $0.dateString == selectedDateString }
    }
    private var scheduled: [TaskItem] { itemsForDay.filter(\.hasTime) }
    private var unscheduled: [TaskItem] {
        itemsForDay.filter { !$0.hasTime }.sorted { a, b in
            if a.isDone != b.isDone { return !a.isDone }
            return a.createdAt < b.createdAt
        }
    }

    /// Nothing here vanishes at midnight: anything left undone on a day
    /// that's already passed surfaces here (today only) until you finish
    /// it, delete it, or reschedule it.
    private var overdueItems: [TaskItem] {
        guard isToday else { return [] }
        return store.tasks
            .filter { !$0.isDone && $0.dateString < selectedDateString }
            .sorted { $0.dateString < $1.dateString }
    }

    var body: some View {
        VStack(spacing: 0) {
            dayHeader
            Divider()
            quickAddBar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !overdueItems.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Overdue")
                                .font(.headline)
                                .foregroundStyle(.red)
                            ForEach(overdueItems) { task in
                                UnscheduledRow(
                                    task: task,
                                    dateLabel: Self.shortDateLabel(task.dateString),
                                    onToggle: { store.toggleDone(task) },
                                    onDelete: { store.deleteTask(task) },
                                    onTap: { editorTarget = .edit(task) }
                                )
                            }
                        }
                    }

                    DayTimelineView(
                        items: scheduled,
                        isToday: isToday,
                        onTap: { editorTarget = .edit($0) },
                        onToggle: { store.toggleDone($0) }
                    )

                    if !unscheduled.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Unscheduled")
                                .font(.headline)
                            ForEach(unscheduled) { task in
                                UnscheduledRow(
                                    task: task,
                                    dateLabel: nil,
                                    onToggle: { store.toggleDone(task) },
                                    onDelete: { store.deleteTask(task) },
                                    onTap: { editorTarget = .edit(task) }
                                )
                            }
                        }
                    }

                    if itemsForDay.isEmpty {
                        Text("Nothing on \(isToday ? "today" : "this day") yet — quick-add a task below, or hit + for a meeting with a time and a link.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .padding(.top, 40)
                    }
                }
                .padding()
            }

            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 680)
        .sheet(item: $editorTarget) { target in
            switch target {
            case .new:
                TaskEditorSheet(store: store, editingTask: nil, defaultDate: selectedDate) {
                    editorTarget = nil
                }
            case .edit(let task):
                TaskEditorSheet(store: store, editingTask: task, defaultDate: selectedDate) {
                    editorTarget = nil
                }
            }
        }
    }

    private var dayHeader: some View {
        HStack {
            Button { changeDay(by: -1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain)

            VStack(spacing: 2) {
                Text(dayTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                if !isToday {
                    Button("Today") { selectedDate = Date() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.aircallAccent)
                }
            }
            .frame(maxWidth: .infinity)

            Button { changeDay(by: 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain)
        }
        .padding()
    }

    private var quickAddBar: some View {
        HStack {
            TextField("Quick-add a task for this day…", text: $quickAddText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    store.addTask(title: quickAddText, dateString: selectedDateString)
                    quickAddText = ""
                }
            Button {
                editorTarget = .new
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help("New task or meeting with a time, tags, link, and notes")
        }
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    private var footer: some View {
        HStack {
            Text(store.tasksFolder.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Reveal in Finder") {
                store.revealInFinder()
            }
            .font(.caption)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var dayTitle: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        let formatted = f.string(from: selectedDate)
        return isToday ? "Today · \(formatted)" : formatted
    }

    private static func shortDateLabel(_ dateString: String) -> String {
        guard let date = TaskFile.dateOnlyFormatter.date(from: dateString) else { return dateString }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    private func changeDay(by delta: Int) {
        if let newDate = Calendar.current.date(byAdding: .day, value: delta, to: selectedDate) {
            selectedDate = newDate
        }
    }
}

private struct UnscheduledRow: View {
    let task: TaskItem
    var dateLabel: String? = nil
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
                // Tap-to-edit is scoped to title+tags only, never the
                // description below, so a link inside it is never in
                // competition with the edit gesture for a tap.
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .strikethrough(task.isDone)
                        .foregroundStyle(task.isDone ? .secondary : .primary)

                    if dateLabel != nil || !task.tags.isEmpty {
                        HStack(spacing: 4) {
                            if let dateLabel {
                                TagPill(text: dateLabel, tint: .red)
                            }
                            ForEach(task.tags, id: \.self) { tag in
                                TagPill(text: tag)
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)

                if !task.rawBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    MarkdownText(text: task.rawBody)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

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
        .padding(.vertical, 3)
    }
}
