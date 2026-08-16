import Foundation
import Combine
import AppKit
import ToDoCore

/// Loads, watches, and mutates the `.md` task files in the `Tasks` folder
/// that sits next to this app (or, when run via `swift run` during
/// development, next to the source checkout). The folder is the single
/// source of truth — this app and Claude Code (or anyone in Finder) can
/// both read and write it directly.
@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = []

    /// Set whenever a write fails. Every mutation used to swallow its error
    /// with `try?`, so a failed save looked exactly like a successful one —
    /// the sheet closed, the list reloaded, and the edit was simply gone.
    /// ContentView presents this as an alert.
    @Published var lastError: StoreError?

    struct StoreError: Identifiable {
        let id = UUID()
        let message: String
        let detail: String
    }

    let tasksFolder: URL

    /// Backstop poll interval. The directory watcher below catches file
    /// creation, deletion, and atomic rename-into-place (which is how both
    /// this app and the MCP server write), so this only needs to cover
    /// in-place edits by an external text editor — a rarer case that can
    /// tolerate a couple of seconds.
    private static let pollInterval: TimeInterval = 2.0

    /// Holds the two long-lived observers so they can be torn down without a
    /// `deinit` on this class. A `deinit` is always non-isolated, so reaching
    /// into `@MainActor` stored properties from one is a warning today and an
    /// error under the Swift 6 language mode. Letting an ordinary,
    /// non-isolated object own them sidesteps that: when the store goes away
    /// this box goes with it and cleans up in its own `deinit`.
    private final class Watchers {
        var timer: Timer?
        var source: DispatchSourceFileSystemObject?

        deinit {
            timer?.invalidate()
            source?.cancel()
        }
    }

    private let watchers = Watchers()
    private var lastSignature: String = ""

    init() {
        tasksFolder = TaskStore.resolveTasksFolder()
        try? FileManager.default.createDirectory(at: tasksFolder, withIntermediateDirectories: true)
        reload()
        startWatching()
        startPolling()
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

    // MARK: - Change detection

    /// A kernel-level watch on the directory: an external write shows up
    /// essentially instantly instead of on the next poll tick, and costs
    /// nothing while the folder is idle. Previously this was a 1-second
    /// timer that stat'd every file in the folder, forever.
    private func startWatching() {
        let descriptor = open(tasksFolder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.reloadIfChanged()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watchers.source = source
    }

    private func startPolling() {
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reloadIfChanged()
            }
        }
        // `.common` rather than the default mode: a timer registered in
        // `.default` alone stops firing while a menu is open or a scroll is
        // tracking — precisely when the menu bar glance is on screen.
        RunLoop.main.add(timer, forMode: .common)
        watchers.timer = timer
    }

    /// Cheap change detection so an external edit (Claude writing a file)
    /// shows up without rebuilding the list — and thus resetting any
    /// in-progress UI state — on every single tick.
    private func directorySignature(from urls: [URL]) -> String {
        var latest: TimeInterval = 0
        for url in urls {
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                latest = max(latest, date.timeIntervalSince1970)
            }
        }
        return "\(urls.count)-\(latest)"
    }

    private func taskFileURLs() -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: tasksFolder,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.filter { $0.pathExtension.lowercased() == "md" }
    }

    func reloadIfChanged() {
        let urls = taskFileURLs()
        let signature = directorySignature(from: urls)
        guard signature != lastSignature else { return }
        load(urls: urls, signature: signature)
    }

    func reload() {
        let urls = taskFileURLs()
        load(urls: urls, signature: directorySignature(from: urls))
    }

    /// The signature is computed from the *same* directory listing the tasks
    /// are read from and recorded up front. Recomputing it afterwards (as
    /// this used to) folds any write that landed mid-read into the accepted
    /// state, so that change would never be picked up.
    private func load(urls: [URL], signature: String) {
        lastSignature = signature

        let loaded: [TaskItem] = urls.compactMap { url in
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return TaskFile.parse(url: url, contents: contents, modifiedAt: modifiedAt)
        }

        tasks = loaded.sorted { a, b in
            if a.isDone != b.isDone {
                return !a.isDone // not-done first
            }
            return a.createdAt < b.createdAt
        }
    }

    // MARK: - Mutation

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
        do {
            try write(contents, to: url, expectedModifiedAt: nil)
        } catch {
            report(error, action: "create “\(trimmed)”")
        }
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
        do {
            try write(contents, to: task.url, expectedModifiedAt: task.modifiedAt)
        } catch {
            report(error, action: "save “\(task.title)”")
        }
        reload()
    }

    func toggleDone(_ task: TaskItem) {
        let newContents = TaskFile.serialize(task, isDone: !task.isDone)
        do {
            try write(newContents, to: task.url, expectedModifiedAt: task.modifiedAt)
        } catch {
            report(error, action: "update “\(task.title)”")
        }
        reload()
    }

    func deleteTask(_ task: TaskItem) {
        // Move to Trash rather than permanently deleting — Finder-native
        // and reversible, matching the "it's just files" design.
        do {
            try FileManager.default.trashItem(at: task.url, resultingItemURL: nil)
        } catch {
            report(error, action: "delete “\(task.title)”")
        }
        reload()
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([tasksFolder])
    }

    /// All tags currently in use, for display convenience.
    var allTags: [String] {
        Array(Set(tasks.flatMap(\.tags))).sorted()
    }

    // MARK: - Writing

    enum WriteError: LocalizedError {
        /// The file changed underneath us between being read and being
        /// written. Both this app and the MCP server rewrite the whole file
        /// from a snapshot, so without this check whichever one saves second
        /// silently erases the other's work.
        case staleSnapshot
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .staleSnapshot:
                return "This item was changed by something else (Claude, or a text editor) after the app read it. "
                    + "Your change was not saved, so nothing was overwritten — reopen the item and redo the edit."
            case .underlying(let error):
                return error.localizedDescription
            }
        }
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
    /// place, so a reload never observes a half-written file.
    ///
    /// `expectedModifiedAt` is the optimistic-concurrency check — pass the
    /// mtime the task was read at, or nil for a brand-new file.
    private func write(_ contents: String, to url: URL, expectedModifiedAt: Date?) throws {
        let fm = FileManager.default

        if let expectedModifiedAt {
            let current = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let current else { throw WriteError.staleSnapshot } // deleted out from under us
            // Filesystem timestamp resolution varies; a second of slack
            // avoids false alarms without weakening the check meaningfully.
            if abs(current.timeIntervalSince(expectedModifiedAt)) > 1.0 {
                throw WriteError.staleSnapshot
            }
        }

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try contents.write(to: tempURL, atomically: false, encoding: .utf8)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tempURL)
            } else {
                // replaceItemAt requires an existing destination — without
                // this branch, saving an item whose file had been removed
                // threw and (previously) failed silently.
                try fm.moveItem(at: tempURL, to: url)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            throw WriteError.underlying(error)
        }
    }

    private func report(_ error: Error, action: String) {
        let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = StoreError(message: "Couldn't \(action).", detail: detail)
    }
}
