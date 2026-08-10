import Foundation

/// A task, or a time-blocked meeting — backed one-to-one by a markdown file
/// on disk. See README.md for the full file-format spec and the
/// calendar-event-to-file mapping Claude follows.
enum TaskKind: String {
    case task
    case meeting

    static func from(_ raw: String?) -> TaskKind {
        if let raw, raw.trimmingCharacters(in: .whitespaces).lowercased() == "meeting" {
            return .meeting
        }
        return .task
    }
}

struct TaskItem: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    var title: String
    var kind: TaskKind
    var isDone: Bool
    var dateString: String   // "yyyy-MM-dd", the scheduled local calendar day
    var startMinutes: Int?   // minutes since local midnight, 0...1439
    var endMinutes: Int?
    var tags: [String]
    var link: URL?
    var createdAt: Date

    /// Raw frontmatter lines (between the `---` fences) exactly as read from
    /// disk, in original order — including comments, blank lines, and any
    /// key this app doesn't know about. Every rewrite (toggling done,
    /// editing via the sheet) goes through `TaskFile.setValue` so this
    /// content survives byte-for-byte except for the one line being
    /// changed. `nil` if the file had no parseable frontmatter block.
    var rawFrontmatterLines: [String]?

    /// Everything after the closing `---` fence, verbatim — this is the
    /// task's description/notes, rendered as markdown so `[label](url)`
    /// and bare URLs become clickable.
    var rawBody: String

    var hasTime: Bool { startMinutes != nil }
}

enum TaskFile {
    /// Keys this app understands. Anything else in a file's frontmatter is
    /// opaque to us and always passed through untouched.
    static let knownKeys: Set<String> = [
        "title", "kind", "done", "date", "start", "end", "tags", "link", "created"
    ]

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func todayString(_ date: Date = Date()) -> String {
        dateOnlyFormatter.string(from: date)
    }

    // MARK: - Parsing

    /// Parses a task file's raw text into a `TaskItem`. Never throws —
    /// malformed files degrade gracefully (title = filename) rather than
    /// being skipped or deleted.
    static func parse(url: URL, contents: String) -> TaskItem {
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closingIndex = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else {
            // No frontmatter: whole file is body, fall back to filename title.
            let stem = url.deletingPathExtension().lastPathComponent
            let fallbackTitle = stem
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
            let createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            return TaskItem(
                url: url,
                title: fallbackTitle.isEmpty ? stem : fallbackTitle,
                kind: .task,
                isDone: false,
                dateString: todayString(createdAt),
                startMinutes: nil,
                endMinutes: nil,
                tags: [],
                link: nil,
                createdAt: createdAt,
                rawFrontmatterLines: nil,
                rawBody: normalized
            )
        }

        let frontmatterLines = Array(lines[1..<closingIndex])
        let bodyStartIndex = closingIndex + 1
        let body = bodyStartIndex < lines.count
            ? lines[bodyStartIndex...].joined(separator: "\n")
            : ""

        var title: String?
        var kindRaw: String?
        var isDone = false
        var dateRaw: String?
        var startRaw: String?
        var endRaw: String?
        var tagsRaw: String?
        var linkRaw: String?
        var createdAt: Date?

        for line in frontmatterLines {
            guard let key = keyOf(line) else { continue }
            let value = valueOf(line)
            switch key {
            case "title": title = value
            case "kind": kindRaw = value
            case "done": isDone = value.lowercased() == "true"
            case "date": dateRaw = value
            case "start": startRaw = value
            case "end": endRaw = value
            case "tags": tagsRaw = value
            case "link": linkRaw = value
            case "created": createdAt = isoFormatter.date(from: value)
            default: break // unknown key — preserved verbatim in rawFrontmatterLines
            }
        }

        let resolvedCreatedAt = createdAt
            ?? (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            ?? Date()

        let stem = url.deletingPathExtension().lastPathComponent
        let resolvedDate = dateRaw.flatMap { dateOnlyFormatter.date(from: $0) != nil ? $0 : nil }
            ?? todayString(resolvedCreatedAt)

        let tags = (tagsRaw ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return TaskItem(
            url: url,
            title: title?.isEmpty == false ? title! : stem,
            kind: TaskKind.from(kindRaw),
            isDone: isDone,
            dateString: resolvedDate,
            startMinutes: startRaw.flatMap(parseMinutes),
            endMinutes: endRaw.flatMap(parseMinutes),
            tags: tags,
            link: linkRaw.flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) },
            createdAt: resolvedCreatedAt,
            rawFrontmatterLines: frontmatterLines,
            rawBody: body
        )
    }

    /// Extracts the lowercased key from a `key: value` frontmatter line.
    /// Comment lines (`#…`) and anything without a colon never match, so
    /// they're never mistaken for a known key and always pass through.
    private static func keyOf(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let colonRange = line.range(of: ":") else { return nil }
        return line[line.startIndex..<colonRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    private static func valueOf(_ line: String) -> String {
        guard let colonRange = line.range(of: ":") else { return "" }
        return line[colonRange.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    /// Parses "HH:mm" (24h) or "h:mm a" into minutes since midnight.
    static func parseMinutes(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ":")
        if parts.count == 2,
           let h = Int(parts[0].trimmingCharacters(in: .whitespaces)),
           let m = Int(parts[1].prefix(2)),
           (0...23).contains(h), (0...59).contains(m) {
            return h * 60 + m
        }

        // Fallback: "9:00 AM" / "9:00am" style.
        for format in ["h:mm a", "h:mma"] {
            let f = DateFormatter()
            f.dateFormat = format
            f.locale = Locale(identifier: "en_US_POSIX")
            if let date = f.date(from: trimmed) {
                let cal = Calendar(identifier: .gregorian)
                let comps = cal.dateComponents([.hour, .minute], from: date)
                if let h = comps.hour, let m = comps.minute {
                    return h * 60 + m
                }
            }
        }
        return nil
    }

    static func formatMinutesHHmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    static func formatMinutesDisplay(_ minutes: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.locale = Locale(identifier: "en_US_POSIX")
        var comps = DateComponents()
        comps.hour = minutes / 60
        comps.minute = minutes % 60
        let cal = Calendar(identifier: .gregorian)
        guard let date = cal.date(from: comps) else { return "" }
        return f.string(from: date)
    }

    // MARK: - Mutation

    /// Finds the line for `key` (case-insensitive) and replaces its value in
    /// place; appends a new line just before the closing fence if the key
    /// isn't present; removes the line entirely if `value` is `nil`. Every
    /// other line — including ones this app doesn't understand — is left
    /// untouched, in its original position. This is the single mutation
    /// path used by every save, so the preserve-unknown-data guarantee
    /// holds everywhere, not just for `done`.
    static func setValue(_ value: String?, forKey key: String, in lines: [String]) -> [String] {
        var lines = lines
        if let idx = lines.firstIndex(where: { keyOf($0) == key }) {
            if let value {
                lines[idx] = "\(key): \(value)"
            } else {
                lines.remove(at: idx)
            }
        } else if let value {
            lines.append("\(key): \(value)")
        }
        return lines
    }

    /// Re-serializes a task, flipping only the `done` value.
    static func serialize(_ task: TaskItem, isDone: Bool) -> String {
        applyingEdits(to: task) { lines in
            setValue(String(isDone), forKey: "done", in: lines)
        }
    }

    /// Re-serializes a task after a full edit from the New/Edit sheet. Only
    /// the fields the sheet actually exposes are touched; comments, blank
    /// lines, and unknown keys survive exactly as they were.
    static func serializeEdit(
        _ task: TaskItem,
        title: String,
        kind: TaskKind,
        dateString: String,
        startMinutes: Int?,
        endMinutes: Int?,
        tags: [String],
        link: String,
        body: String
    ) -> String {
        applyingEdits(to: task, body: body) { lines in
            var lines = lines
            lines = setValue(title, forKey: "title", in: lines)
            lines = setValue(kind == .meeting ? "meeting" : nil, forKey: "kind", in: lines)
            lines = setValue(dateString, forKey: "date", in: lines)
            lines = setValue(startMinutes.map(formatMinutesHHmm), forKey: "start", in: lines)
            lines = setValue(endMinutes.map(formatMinutesHHmm), forKey: "end", in: lines)
            lines = setValue(tags.isEmpty ? nil : tags.joined(separator: ", "), forKey: "tags", in: lines)
            let trimmedLink = link.trimmingCharacters(in: .whitespaces)
            lines = setValue(trimmedLink.isEmpty ? nil : trimmedLink, forKey: "link", in: lines)
            return lines
        }
    }

    private static func applyingEdits(
        to task: TaskItem,
        body: String? = nil,
        _ edit: ([String]) -> [String]
    ) -> String {
        let baseLines = task.rawFrontmatterLines ?? []
        let newLines = edit(baseLines)
        let resolvedBody = body ?? task.rawBody
        if task.rawFrontmatterLines != nil {
            return "---\n" + newLines.joined(separator: "\n") + "\n---\n" + resolvedBody
        } else {
            // File had no frontmatter to begin with — synthesize one, keep
            // the original content as the body underneath.
            let created = isoFormatter.string(from: task.createdAt)
            var lines = newLines
            lines = setValue(created, forKey: "created", in: lines)
            return "---\n" + lines.joined(separator: "\n") + "\n---\n" + resolvedBody
        }
    }

    // MARK: - New file creation

    /// Builds the initial file content for a brand-new task or meeting.
    static func newFileContents(
        title: String,
        kind: TaskKind,
        dateString: String,
        startMinutes: Int?,
        endMinutes: Int?,
        tags: [String],
        link: String,
        body: String,
        createdAt: Date
    ) -> String {
        var lines: [String] = []
        lines.append("title: \(title)")
        if kind == .meeting { lines.append("kind: meeting") }
        lines.append("done: false")
        lines.append("date: \(dateString)")
        if let startMinutes { lines.append("start: \(formatMinutesHHmm(startMinutes))") }
        if let endMinutes { lines.append("end: \(formatMinutesHHmm(endMinutes))") }
        if !tags.isEmpty { lines.append("tags: \(tags.joined(separator: ", "))") }
        let trimmedLink = link.trimmingCharacters(in: .whitespaces)
        if !trimmedLink.isEmpty { lines.append("link: \(trimmedLink)") }
        lines.append("created: \(isoFormatter.string(from: createdAt))")
        let trimmedBody = body.isEmpty ? "" : "\n\(body)"
        return "---\n" + lines.joined(separator: "\n") + "\n---\n" + trimmedBody
    }

    /// Builds a stable, human-readable filename from the creation instant.
    /// Filenames are never changed after creation — rescheduling a task
    /// only ever touches its `date`/`start`/`end` frontmatter.
    static func newFilename(title: String, createdAt: Date) -> String {
        let stampFormatter = DateFormatter()
        stampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        stampFormatter.timeZone = TimeZone(identifier: "UTC")
        let stamp = stampFormatter.string(from: createdAt)

        let slug = title
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, char in
                if char == "-" && result.hasSuffix("-") { return }
                result.append(char)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        let safeSlug = slug.isEmpty ? "task" : String(slug.prefix(40))
        return "\(stamp)-\(safeSlug).md"
    }
}
