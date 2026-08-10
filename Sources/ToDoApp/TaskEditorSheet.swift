import SwiftUI

/// The "New item" / "Edit item" form. Used for both creating a task or
/// meeting from the UI and editing one you tap on. Quick, keyboard-only
/// capture still goes through the text field in the toolbar — this sheet is
/// for anything that needs a time, tags, a link, or notes.
struct TaskEditorSheet: View {
    @ObservedObject var store: TaskStore
    let editingTask: TaskItem?
    let defaultDate: Date
    let onDismiss: () -> Void

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

    init(store: TaskStore, editingTask: TaskItem?, defaultDate: Date, onDismiss: @escaping () -> Void) {
        self.store = store
        self.editingTask = editingTask
        self.defaultDate = defaultDate
        self.onDismiss = onDismiss

        let cal = Calendar.current
        let defaultStart = cal.date(bySettingHour: 9, minute: 0, second: 0, of: defaultDate) ?? defaultDate

        if let task = editingTask {
            _title = State(initialValue: task.title)
            _kind = State(initialValue: task.kind)
            _date = State(initialValue: TaskFile.dateOnlyFormatter.date(from: task.dateString) ?? defaultDate)
            _hasTime = State(initialValue: task.startMinutes != nil)
            _startTime = State(initialValue: Self.date(fromMinutes: task.startMinutes, on: defaultDate) ?? defaultStart)
            _hasEndTime = State(initialValue: task.endMinutes != nil)
            _endTime = State(initialValue: Self.date(fromMinutes: task.endMinutes, on: defaultDate) ?? defaultStart)
            _tagsText = State(initialValue: task.tags.joined(separator: ", "))
            _link = State(initialValue: task.link?.absoluteString ?? "")
            _body_ = State(initialValue: task.rawBody.trimmingCharacters(in: .newlines))
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
                if editingTask != nil {
                    Button("Delete", role: .destructive) {
                        showDeleteConfirm = true
                    }
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
        let dateString = TaskFile.dateOnlyFormatter.string(from: date)
        let startMinutes = hasTime ? Self.minutes(from: startTime) : nil
        let endMinutes = (hasTime && hasEndTime) ? Self.minutes(from: endTime) : nil
        let tags = tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if let task = editingTask {
            store.updateTask(
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
            store.createTask(
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
