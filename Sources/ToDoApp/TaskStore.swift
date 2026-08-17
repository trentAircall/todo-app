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
        recordTasksFolderLocation()
        reload()
        startWatching()
        startPolling()
    }

    /// Writes this launch's Tasks path somewhere stable so the MCP server can
    /// find it. The server runs as a separate process that Claude Desktop
    /// copies to its own extensions directory, so it can't work the location
    /// out from its own position on disk — it used to hardcode an absolute
    /// path and create it if missing, which meant moving this folder (which
    /// the README invites) silently split the app and Claude across two
    /// different Tasks folders. Re-recorded on every launch, so moving the
    /// folder and reopening the app is all it takes to re-point the server.
    private func recordTasksFolderLocation() {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return }

        let directory = appSupport.appendingPathComponent("ToDoApp", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? tasksFolder.path.write(
            to: directory.appendingPathComponent("tasks-folder-path"),
            atomically: true,
            encoding: .utf8
        )
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
        // `source` is captured strongly on purpose — reading `source.data` is
        // the only way to learn WHICH event fired, and that matters below.
        // The resulting cycle is broken by Watchers.deinit calling cancel().
        source.setEventHandler { [weak self] in
            let events = source.data
            Task { @MainActor in
                self?.handleDirectoryEvent(events)
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watchers.source = source
    }

    private func handleDirectoryEvent(_ events: DispatchSource.FileSystemEvent) {
        // After the watched directory is deleted or renamed, the descriptor
        // points at a dead or moved inode and the kernel watch is useless
        // forever — every later change would have been caught only by the
        // backstop poll. Re-arm against whatever is at the path now.
        if events.contains(.delete) || events.contains(.rename) {
            watchers.source?.cancel()
            watchers.source = nil
            try? FileManager.default.createDirectory(at: tasksFolder, withIntermediateDirectories: true)
            startWatching()
        }
        reloadIfChanged()
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

    /// `nil` — as distinct from `[]` — means the directory itself could not
    /// be read. Those are very different situations: an empty folder should
    /// empty the list, a transient permission error or an unmounted volume
    /// should leave the last known good list on screen rather than making
    /// the app look like it lost everything.
    private func taskFileURLs() -> [URL]? {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: tasksFolder,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return urls.filter { $0.pathExtension.lowercased() == "md" }
    }

    func reloadIfChanged() {
        guard let urls = taskFileURLs() else { return }
        let signature = directorySignature(from: urls)
        guard signature != lastSignature else { return }
        load(urls: urls, signature: signature)
    }

    func reload() {
        guard let urls = taskFileURLs() else { return }
        load(urls: urls, signature: directorySignature(from: urls))
    }

    /// The signature is computed from the *same* directory listing the tasks
    /// are read from and recorded up front. Recomputing it afterwards (as
    /// this used to) folds any write that landed mid-read into the accepted
    /// state, so that change would never be picked up.
    private func load(urls: [URL], signature: String) {
        lastSignature = signature

        var loaded: [TaskItem] = []
        var unreadable: [String] = []

        for url in urls {
            // Signature BEFORE contents, deliberately. If a write lands
            // between the two, we end up holding new content with an old
            // signature, and the next save is refused — annoying but safe.
            // The other order pairs old content with a fresh signature, and
            // the next save would sail through and clobber.
            let fileSignature = Self.fileSignature(at: url)
            guard let contents = Self.readText(at: url) else {
                unreadable.append(url.lastPathComponent)
                continue
            }
            loaded.append(TaskFile.parse(url: url, contents: contents, signature: fileSignature))
        }

        tasks = loaded.sorted { a, b in
            if a.isDone != b.isDone {
                return !a.isDone // not-done first
            }
            return a.createdAt < b.createdAt
        }

        // A file that can't be read used to just vanish from the list, which
        // reads to the user as "my task got deleted".
        if !unreadable.isEmpty {
            lastError = StoreError(
                message: "Couldn't read \(unreadable.count == 1 ? "a task file" : "\(unreadable.count) task files").",
                detail: "These are still on disk but aren't being shown: \(unreadable.joined(separator: ", ")). "
                    + "Open one in a text editor and re-save it as UTF-8 to bring it back."
            )
        }
    }

    /// UTF-8 first, then whatever encoding the file actually is. Text pasted
    /// from an older document is often Latin-1, and a strict UTF-8 read of it
    /// fails outright.
    private static func readText(at url: URL) -> String? {
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) { return utf8 }
        var detected: String.Encoding = .utf8
        if let fallback = try? String(contentsOf: url, usedEncoding: &detected) { return fallback }
        return nil
    }

    // MARK: - Mutation

    /// Quick-capture: an unscheduled task for the given day, title only.
    func addTask(title: String, dateString: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Quick-add has nowhere to put an error and nothing to lose if it
        // fails (the field is one line, still on screen); the alert from
        // `report` is the whole story here.
        try? createTask(
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
    ///
    /// Throws so the sheet can stay open on failure. It used to swallow the
    /// error and return, and the sheet dismissed unconditionally — so the
    /// one case the staleness check exists to catch was also the case that
    /// threw away whatever the user had just typed.
    @discardableResult
    func createTask(
        title: String,
        kind: TaskKind,
        dateString: String,
        startMinutes: Int?,
        endMinutes: Int?,
        tags: [String],
        link: String,
        body: String
    ) throws -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

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
            try write(contents, to: url, expectedSignature: nil)
            lastError = nil
        } catch {
            report(error, action: "create “\(trimmed)”")
            reload()
            throw error
        }
        reload()
        return true
    }

    /// Full edit path used by the New/Edit sheet on an existing task. Only
    /// the fields the sheet exposes are touched — everything else in the
    /// file (comments, unknown keys) is preserved. Throws for the same
    /// reason createTask does — see above.
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
    ) throws {
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
            try write(contents, to: task.url, expectedSignature: task.signature)
            lastError = nil
        } catch {
            report(error, action: "save “\(task.title)”")
            reload()
            throw error
        }
        reload()
    }

    func toggleDone(_ task: TaskItem) {
        let newContents = TaskFile.serialize(task, isDone: !task.isDone)
        do {
            try write(newContents, to: task.url, expectedSignature: task.signature)
            lastError = nil
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
            lastError = nil
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

    /// An identity token for a file's current contents. Mirrors
    /// `signatureOf` in mcp-server/taskfile.js — mtime, size, inode.
    ///
    /// Read via `FileManager.attributesOfItem`, NOT `url.resourceValues`.
    /// The URLs here come from `contentsOfDirectory(includingPropertiesForKeys:)`,
    /// which pre-fetches and CACHES those properties onto the URL object;
    /// that cache rides along into `TaskItem.url` and survives to here, so
    /// the previous version was at real risk of comparing the load-time
    /// mtime against itself and passing every single time. A dead check is
    /// worse than no check, because it reads as protection.
    static func fileSignature(at url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return "\(modified):\(size):\(inode)"
    }

    /// Writes to a temp file in the same directory, then swaps it into
    /// place, so a reload never observes a half-written file.
    ///
    /// `expectedSignature` is the optimistic-concurrency check — pass the
    /// signature the task was read at, or nil for a brand-new file.
    private func write(_ contents: String, to url: URL, expectedSignature: String?) throws {
        let fm = FileManager.default

        // Strict equality, no tolerance window. This used to allow a full
        // SECOND of drift where the MCP server allowed a millisecond, both
        // claiming to do the same thing — so Claude could write a file and
        // the app could overwrite it 400ms later without complaint.
        func verifyUnchanged() throws {
            guard let expectedSignature else { return }
            guard let current = Self.fileSignature(at: url) else {
                throw WriteError.staleSnapshot // deleted out from under us
            }
            guard current == expectedSignature else { throw WriteError.staleSnapshot }
        }

        try verifyUnchanged()

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try contents.write(to: tempURL, atomically: false, encoding: .utf8)
            // Re-check with the replacement already staged, so the gap
            // between "we looked" and "we swapped" is only the swap itself.
            try verifyUnchanged()
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tempURL)
            } else {
                // replaceItemAt requires an existing destination — without
                // this branch, saving an item whose file had been removed
                // threw and (previously) failed silently.
                try fm.moveItem(at: tempURL, to: url)
            }
        } catch let error as WriteError {
            try? fm.removeItem(at: tempURL)
            throw error
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
