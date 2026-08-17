import SwiftUI
import Combine
import ToDoCore

/// The day run-sheet: a flat, time-sorted list of scheduled tasks/meetings,
/// plus an unscheduled to-do list underneath, for one day at a time. No
/// calendar-grid positioning — just plain rows sorted by time, with
/// double-bookings flagged with a simple text/icon note instead of
/// splitting layout.
struct ContentView: View {
    @ObservedObject var store: TaskStore
    @State private var selectedDate = Date()
    /// The app is built to be left running for days, and `selectedDate` was
    /// set once at init with nothing to advance it. Leave the window open
    /// overnight and the header still said "Today · yesterday" — so a
    /// quick-added task silently landed on the wrong day, straight into the
    /// Overdue pile. This rolls the view forward at midnight, but only while
    /// you're actually looking at today.
    @State private var now = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @State private var quickAddText = ""
    @State private var editorTarget: EditorTarget?
    @State private var searchText = ""
    @FocusState private var searchFieldFocused: Bool

    enum EditorTarget: Identifiable {
        case new
        case edit(TaskItem)
        case followUp(from: TaskItem)
        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let task): return task.id.path
            case .followUp(let task): return "followup-\(task.id.path)"
            }
        }
    }

    private var selectedDateString: String { TaskFile.dateOnlyFormatter.string(from: selectedDate) }
    private var todayString: String { TaskFile.todayString(now) }
    private var isToday: Bool { selectedDateString == todayString }

    private var itemsForDay: [TaskItem] {
        store.tasks.filter { $0.dateString == selectedDateString }
    }
    private var scheduled: [TaskItem] {
        itemsForDay.filter(\.hasTime).sorted { ($0.startMinutes ?? 0) < ($1.startMinutes ?? 0) }
    }
    /// Only live items clash. A meeting you've already ticked off was still
    /// flagging the one that replaced it as "Overlaps another item".
    private var overlappingIDs: Set<URL> {
        TimelineLayout.overlappingTaskIDs(scheduled.filter { !$0.isDone })
    }
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
            .filter { !$0.isDone && $0.dateString < todayString }
            .sorted { a, b in
                // Oldest first, then by time within a day — sorting on the
                // date alone left same-day items in whatever order the
                // directory scan happened to return, which shuffled rows
                // between reloads.
                if a.dateString != b.dateString { return a.dateString < b.dateString }
                if a.startMinutes != b.startMinutes {
                    return (a.startMinutes ?? Int.max) < (b.startMinutes ?? Int.max)
                }
                return a.createdAt < b.createdAt
            }
    }

    /// Typing is what puts the view into search — there's no mode to enter
    /// or leave, and clearing the field puts you back on the day you were on.
    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Cross-day search over every task's title, tags, and description —
    /// the whole `Tasks` folder, not just the day on screen.
    private var searchResults: [TaskItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return store.tasks
            .filter { task in
                task.title.localizedCaseInsensitiveContains(query)
                    || task.tags.joined(separator: " ").localizedCaseInsensitiveContains(query)
                    || task.rawBody.localizedCaseInsensitiveContains(query)
            }
            .sorted { a, b in
                if a.dateString != b.dateString { return a.dateString < b.dateString }
                return (a.startMinutes ?? 0) < (b.startMinutes ?? 0)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            dayHeader
            Divider()
            searchBar
            Divider()
            quickAddBar
            Divider()

            ScrollView {
                if isSearchActive {
                    searchResultsList
                } else {
                    dayContent
                }
            }

            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 680)
        // Only for failures raised OUTSIDE the editor sheet — a failed
        // checkbox toggle, a failed delete, an unreadable file. A save that
        // fails inside the sheet is reported by the sheet itself: an alert
        // attached here would be requested in the same update that tears the
        // sheet down, and SwiftUI drops it.
        .alert(
            store.lastError?.message ?? "Something went wrong.",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } }
            ),
            presenting: store.lastError
        ) { _ in
            Button("OK", role: .cancel) { store.lastError = nil }
        } message: { error in
            Text(error.detail)
        }
        .onReceive(clock) { now = $0 }
        .onAppear { now = Date() }
        // ⌘F jumps to the search field. Zero-size and hidden from the layout;
        // it exists only to own the shortcut.
        .background(
            Button("") { searchFieldFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        .sheet(item: $editorTarget) { target in
            switch target {
            case .new:
                TaskEditorSheet(store: store, editingTask: nil, defaultDate: selectedDate, followUpFrom: nil) {
                    editorTarget = nil
                } onCreateFollowUp: { task in
                    requestFollowUp(from: task)
                }
            case .edit(let task):
                TaskEditorSheet(store: store, editingTask: task, defaultDate: selectedDate, followUpFrom: nil) {
                    editorTarget = nil
                } onCreateFollowUp: { task in
                    requestFollowUp(from: task)
                }
            case .followUp(let source):
                TaskEditorSheet(store: store, editingTask: nil, defaultDate: Date(), followUpFrom: source) {
                    editorTarget = nil
                } onCreateFollowUp: { task in
                    requestFollowUp(from: task)
                }
            }
        }
    }

    private var dayContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !overdueItems.isEmpty {
                section("Overdue", tint: .red) {
                    ForEach(overdueItems) { task in
                        TaskRow(
                            task: task,
                            dateLabel: TaskFile.shortDateLabel(task.dateString),
                            onToggle: { store.toggleDone(task) },
                            onDelete: { store.deleteTask(task) },
                            onTap: { editorTarget = .edit(task) }
                        )
                    }
                }
            }

            if !scheduled.isEmpty {
                section("Schedule") {
                    ForEach(scheduled) { task in
                        TaskRow(
                            task: task,
                            timeLabel: timeRangeLabel(task),
                            isOverlapping: overlappingIDs.contains(task.url),
                            onToggle: { store.toggleDone(task) },
                            onDelete: { store.deleteTask(task) },
                            onTap: { editorTarget = .edit(task) }
                        )
                    }
                }
            }

            if !unscheduled.isEmpty {
                section("Unscheduled") {
                    ForEach(unscheduled) { task in
                        TaskRow(
                            task: task,
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

    private var searchResultsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if searchResults.isEmpty {
                Text("No matches for \u{201C}\(searchText)\u{201D}.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 40)
            } else {
                ForEach(searchResults) { task in
                    TaskRow(
                        task: task,
                        timeLabel: task.hasTime ? timeRangeLabel(task) : nil,
                        dateLabel: TaskFile.shortDateLabel(task.dateString),
                        dateLabelTint: .gray,
                        onToggle: { store.toggleDone(task) },
                        onDelete: { store.deleteTask(task) },
                        onTap: { jumpToResult(task) }
                    )
                }
            }
        }
        .padding()
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        tint: Color = .primary,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .foregroundStyle(tint)
            content()
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

    /// Always on screen rather than hidden behind a toggle. Looking back at
    /// what happened is half of what this app is for, and it used to be a
    /// bare magnifying-glass icon that replaced the quick-add field — so it
    /// read as a mode you had to know about, and most of the time nobody did.
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search every day — titles, tags, and notes", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
                .onSubmit { searchFieldFocused = true }

            if isSearchActive {
                Text(searchResults.count == 1 ? "1 match" : "\(searchResults.count) matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    searchText = ""
                    searchFieldFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search and go back to the day")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
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

    private func timeRangeLabel(_ task: TaskItem) -> String {
        guard let start = task.startMinutes else { return "" }
        guard let end = task.endMinutes else { return TaskFile.formatMinutesDisplay(start) }
        return "\(TaskFile.formatMinutesDisplay(start))–\(TaskFile.formatMinutesDisplay(end))"
    }

    private func changeDay(by delta: Int) {
        if let newDate = Calendar.current.date(byAdding: .day, value: delta, to: selectedDate) {
            selectedDate = newDate
        }
    }

    /// Tapping a search result exits search and lands you on the day it
    /// lives on, with its editor already open — no separate "now go find it"
    /// step.
    private func jumpToResult(_ task: TaskItem) {
        if let date = TaskFile.dateOnlyFormatter.date(from: task.dateString) {
            selectedDate = date
        }
        searchText = ""
        editorTarget = .edit(task)
    }

    /// Closes whatever editor sheet is open and reopens a fresh one primed
    /// for a follow-up task, on the next run-loop tick so SwiftUI never sees
    /// the two sheets' identities swap in the same update.
    private func requestFollowUp(from task: TaskItem) {
        editorTarget = nil
        DispatchQueue.main.async {
            self.editorTarget = .followUp(from: task)
        }
    }
}
