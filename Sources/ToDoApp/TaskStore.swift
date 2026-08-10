import Foundation
import Combine
import AppKit

/// Loads, watches, and mutates the `.md` task files in the `Tasks` folder
/// that sits next to this app (or, when run via `swift run` during
/// development, next to the source checkout). The folder is the single
/// source of truth — this app and Claude Code (or anyone in Finder) can
/// both read and write it directly.
@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = []

    let tasksFolder: URL

    private var pollTimer: Timer?
    private var lastSignature: String = ""

    init() {
        tasksFolder = TaskStore.resolveTasksFolder()
        try? FileManager.default.createDirectory(at: tasksFolder, withIntermediateDirectories: true)
        reload()
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
    }

    /// The `Tasks` folder lives next to the running `.app` bundle so the
    /// whole app + its data stay together as one portable Finder folder.
    /// Falls back to the current working directory for `swift run`.
    static func resolveTasksFolder() -> URL {
        let bundleURL = Bundle.main.bundleURL
        let containingDir: URL
        if bundleURL.pathExtension == "app" {
            containingDir = bundleURL.deletingLastPathComponent()
        } else {
            containingDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }
        return containingDir.appendingPathComponent("Tasks", isDirectory: true)
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reloadIfChanged()
            }
        }
    }

    /// Cheap change detection so an external edit (Claude writing a file)
    /// shows up within ~1s without rebuilding the list — and thus resetting
    /// any in-progress UI state — on every single tick.
    private func directorySignature() -> String {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: tasksFolder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "empty"
        }
        let mdFiles = urls.filter { $0.pathExtension.lowercased() == "md" }
        var latest: TimeInterval = 0
        for url in mdFiles {
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                latest = max(latest, date.timeIntervalSince1970)
            }
        }
        return "\(mdFiles.count)-\(latest)"
    }

    func reloadIfChanged() {
        let signature = directorySignature()
        guard signature != lastSignature else { return }
        lastSignature = signature
        reload()
    }

    func reload() {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: tasksFolder,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            tasks = []
            return
        }

        let loaded: [TaskItem] = urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url in
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return TaskFile.parse(url: url, contents: contents)
            }

        tasks = loaded.sorted { a, b in
            if a.isDone != b.isDone {
                return !a.isDone // not-done first
            }
            return a.createdAt < b.createdAt
        }
        lastSignature = directorySignature()
    }

    /// Quick-capture: an unscheduled task for the given day, title only.
    func addTask(title: String, dateString: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        createTask(
            title: trimmed,
            kind: .task,
            dateString: dateString,
            startMinutes: nil,
            endMinutes: nil,
            tags: [],
            link: "",
            body: ""
        )
    }

    /// Full creation path used by the New/Edit sheet.
    func createTask(
        title: String,
        kind: TaskKind,
        dateString: String,
        startMinutes: Int?,
        endMinutes: Int?,
        tags: [String],
        link: String,
        body: String
    ) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let now = Date()
        let url = uniqueFileURL(for: TaskFile.newFilename(title: trimmed, createdAt: now))
        let contents = TaskFile.newFileContents(
            title: trimmed,
            kind: kind,
            dateString: dateString,
            startMinutes: startMinutes,
            endMinutes: endMinutes,
            tags: tags,
            link: link,
            body: body,
            createdAt: now
        )
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        reload()
    }

    /// Full edit path used by the New/Edit sheet on an existing task. Only
    /// the fields the sheet exposes are touched — everything else in the
    /// file (comments, unknown keys) is preserved.
    func updateTask(
        _ task: TaskItem,
        title: String,
        kind: TaskKind,
        dateString: String,
        startMinutes: Int?,
        endMinutes: Int?,
        tags: [String],
        link: String,
        body: String
    ) {
        let contents = TaskFile.serializeEdit(
            task,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            dateString: dateString,
            startMinutes: startMinutes,
            endMinutes: endMinutes,
            tags: tags,
            link: link,
            body: body
        )
        writeAtomically(contents, to: task.url)
        reload()
    }

    func toggleDone(_ task: TaskItem) {
        let newValue = !task.isDone
        let newContents = TaskFile.serialize(task, isDone: newValue)
        writeAtomically(newContents, to: task.url)
        reload()
    }

    func deleteTask(_ task: TaskItem) {
        // Move to Trash rather than permanently deleting — Finder-native
        // and reversible, matching the "it's just files" design.
        try? FileManager.default.trashItem(at: task.url, resultingItemURL: nil)
        reload()
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([tasksFolder])
    }

    /// All tags currently in use, for display convenience.
    var allTags: [String] {
        Array(Set(tasks.flatMap(\.tags))).sorted()
    }

    /// Resolves filename collisions (e.g. several files created within the
    /// same second) by appending -2, -3, … before the extension.
    private func uniqueFileURL(for filename: String) -> URL {
        var url = tasksFolder.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return url }

        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var counter = 2
        repeat {
            url = tasksFolder.appendingPathComponent("\(stem)-\(counter).\(ext)")
            counter += 1
        } while FileManager.default.fileExists(atPath: url.path)
        return url
    }

    /// Writes to a temp file in the same directory, then swaps it into
    /// place, so the polling reload never observes a half-written file.
    private func writeAtomically(_ contents: String, to url: URL) {
        let fm = FileManager.default
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try contents.write(to: tempURL, atomically: false, encoding: .utf8)
            _ = try fm.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            try? fm.removeItem(at: tempURL)
        }
    }
}
