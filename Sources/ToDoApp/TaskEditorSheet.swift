import SwiftUI
import ToDoCore

/// The "New item" / "Edit item" form. Used for both creating a task or
/// meeting from the UI and editing one you tap on. Quick, keyboard-only
/// capture still goes through the text field in the toolbar — this sheet is
/// for anything that needs a time, tags, a link, or notes.
struct TaskEditorSheet: View {
    @ObservedObject var store: TaskStore
    let editingTask: TaskItem?
    let defaultDate: Date
    /// Set only when this sheet was opened via "Create Follow-up" on another
    /// task — used purely to prefill title/tags/notes at init time.
    let followUpFrom: TaskItem?
    let onDismiss: () -> Void
    /// Tapped from the bottom bar on an existing task — asks the parent to
    /// swap this sheet for a fresh one prefilled as a follow-up of `task`.
    let onCreateFollowUp: (TaskItem) -> Void

    @State private var title: String
    @State private var kind: TaskKind
    @State private var date: Date
    @State private var hasTime: Bool
    @State private var startTime: Date
    @State private var hasEndTime: Bool
    @State private var endTime: Date
    @State private var tagsText: String
    @State private var link: String
    @State private var body_: String
    @State private var showDeleteConfirm = false
    /// Set when a save fails. The sheet stays open and shows this, because
    /// the failure that matters most — someone else changed the file while
    /// you were typing — is exactly the one where dismissing would throw
    /// away the text you'd just written.
    @State private var saveError: String?

    init(
        store: TaskStore,
        editingTask: TaskItem?,
        defaultDate: Date,
        followUpFrom: TaskItem? = nil,
        onDismiss: @escaping () -> Void,
        onCreateFollowUp: @escaping (TaskItem) -> Void
    ) {
        self.store = store
        self.editingTask = editingTask
        self.defaultDate = defaultDate
        self.followUpFrom = followUpFrom
        self.onDismiss = onDismiss
        self.onCreateFollowUp = onCreateFollowUp

        let cal = Calendar.current
        let defaultStart = cal.date(bySettingHour: 9, minute: 0, second: 0, of: defaultDate) ?? defaultDate

        if let task = editingTask {
            // Anchor the time pickers on the task's OWN day, not the day
            // that happens to be on screen. Only h:mm is read back on save,
            // so this was invisible day to day — but building 9:00 on the
            // wrong date is exactly how a DST-transition day produces a
            // time that doesn't exist and silently shifts by an hour.
            let taskDay = TaskFile.dateOnlyFormatter.date(from: task.dateString) ?? defaultDate
            _title = State(initialValue: task.title)
            _kind = State(initialValue: task.kind)
            _date = State(initialValue: taskDay)
            _hasTime = State(initialValue: task.startMinutes != nil)
            _startTime = State(initialValue: Self.date(fromMinutes: task.startMinutes, on: taskDay) ?? defaultStart)
            _hasEndTime = State(initialValue: task.endMinutes != nil)
            _endTime = State(initialValue: Self.date(fromMinutes: task.endMinutes, on: taskDay) ?? defaultStart)
            _tagsText = State(initialValue: task.tags.joined(separator: ", "))
            _link = State(initialValue: task.link?.absoluteString ?? "")
            _body_ = State(initialValue: task.rawBody.trimmingCharacters(in: .newlines))
        } else if let source = followUpFrom {
            // Prefilled from "Create Follow-up" — the provenance note lives
            // as a plain line in the body (no new frontmatter key needed),
            // so it shows up automatically in the row's description preview.
            _title = State(initialValue: "Follow up: \(source.title)")
            _kind = State(initialValue: .task)
            _date = State(initialValue: defaultDate)
            _hasTime = State(initialValue: false)
            _startTime = State(initialValue: defaultStart)
            _hasEndTime = State(initialValue: false)
            _endTime = State(initialValue: defaultStart)
            _tagsText = State(initialValue: source.tags.joined(separator: ", "))
            _link = State(initialValue: "")
            _body_ = State(initialValue: "**Follow-up from:** \(source.title) — \(TaskFile.shortDateLabel(source.dateString))\n\n")
        } else {
            _title = State(initialValue: "")
            _kind = State(initialValue: .task)
            _date = State(initialValue: defaultDate)
            _hasTime = State(initialValue: false)
            _startTime = State(initialValue: defaultStart)
            _hasEndTime = State(initialValue: false)
            _endTime = State(initialValue: defaultStart)
            _tagsText = State(initialValue: "")
            _link = State(initialValue: "")
            _body_ = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("Title") {
                        TextField("", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .font(.title3)
                    }

                    field("Type") {
                        Picker("", selection: $kind) {
                            Text("Task").tag(TaskKind.task)
                            Text("Meeting").tag(TaskKind.meeting)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }

                    field("Date") {
                        DatePicker("", selection: $date, displayedComponents: .date)
                            .labelsHidden()
                    }

                    Toggle("Scheduled at a specific time", isOn: $hasTime.animation())

                    if hasTime {
                        HStack(alignment: .top, spacing: 20) {
                            field("Start") {
                                DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute)
                                    .labelsHidden()
                            }
                            if hasEndTime {
                                field("End") {
                                    DatePicker("", selection: $endTime, displayedComponents: .hourAndMinute)
                                        .labelsHidden()
                                }
                            }
                        }
                        Toggle("Has an end time", isOn: $hasEndTime.animation())
                    }

                    field("Tags (comma separated)") {
                        TextField("", text: $tagsText)
                            .textFieldStyle(.roundedBorder)
                    }

                    field("Link (Zoom, Meet, doc, etc.)") {
                        TextField("", text: $link)
                            .textFieldStyle(.roundedBorder)
                    }

                    field("Description") {
                        VStack(alignment: .leading, spacing: 4) {
                            TextEditor(text: $body_)
                                .frame(minHeight: 100)
                                .font(.body)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                )
                            Text("Markdown links work: [Slides](https://…) — bare URLs become clickable too.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        field("Preview (links are clickable here)") {
                            MarkdownText(text: body_)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .padding()
            }

            Divider()

            HStack {
                if let task = editingTask {
                    Button("Delete", role: .destructive) {
                        showDeleteConfirm = true
                    }
                    Button {
                        onCreateFollowUp(task)
                    } label: {
                        Label("Follow-up", systemImage: "arrow.turn.up.right")
                    }
                    .help("Create a new task that notes it followed on from this one")
                }
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 460, height: 620)
        .alert(
            "Couldn't save this item.",
            isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } }),
            presenting: saveError
        ) { _ in
            Button("OK", role: .cancel) { saveError = nil }
        } message: { message in
            Text(message)
        }
        .confirmationDialog(
            "Delete this item?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let task = editingTask {
                    store.deleteTask(task)
                }
                onDismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It'll be moved to the Trash, not permanently deleted.")
        }
    }

    private func save() {
        saveError = nil
        let dateString = TaskFile.dateOnlyFormatter.string(from: date)
        let startMinutes = hasTime ? Self.minutes(from: startTime) : nil
        let endMinutes = (hasTime && hasEndTime) ? Self.minutes(from: endTime) : nil
        let tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        do {
            if let task = editingTask {
                try store.updateTask(
                    task,
                    title: title,
                    kind: kind,
                    dateString: dateString,
                    startMinutes: startMinutes,
                    endMinutes: endMinutes,
                    tags: tags,
                    link: link,
                    body: body_
                )
            } else {
                try store.createTask(
                    title: title,
                    kind: kind,
                    dateString: dateString,
                    startMinutes: startMinutes,
                    endMinutes: endMinutes,
                    tags: tags,
                    link: link,
                    body: body_
                )
            }
        } catch {
            // Deliberately no onDismiss() here. Everything the user typed is
            // in this sheet's @State and nowhere else yet.
            saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        onDismiss()
    }

    private static func minutes(from date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    private static func date(fromMinutes minutes: Int?, on day: Date) -> Date? {
        guard let minutes else { return nil }
        return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
    }

    /// One label-above-control row — the whole sheet is a single column of
    /// these, rather than a two-column label-left/control-right form.
    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }
}
