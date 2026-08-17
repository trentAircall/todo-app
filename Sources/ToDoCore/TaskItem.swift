import Foundation

/// The task model and file format. Deliberately Foundation-only and in its
/// own module so it can be unit-tested without dragging in SwiftUI/AppKit —
/// see Tests/ToDoCoreTests.
///
/// This file has a twin: mcp-server/taskfile.js implements the same format
/// in JavaScript. The two are held together by Tests/fixtures/cases.json,
/// which both test suites assert against. Change parsing behaviour here and
/// you must change it there; the fixtures will tell you if you forget.

/// A task, or a time-blocked meeting — backed one-to-one by a markdown file
/// on disk. See README.md for the full file-format spec and the
/// calendar-event-to-file mapping Claude follows.
public enum TaskKind: String, Sendable, CaseIterable {
    case task
    case meeting

    public static func from(_ raw: String?) -> TaskKind {
        if let raw, raw.trimmingCharacters(in: .whitespaces).lowercased() == "meeting" {
            return .meeting
        }
        return .task
    }
}

public struct TaskItem: Identifiable, Equatable, Sendable {
    public var id: URL { url }
    public let url: URL
    public var title: String
    public var kind: TaskKind
    public var isDone: Bool
    public var dateString: String   // "yyyy-MM-dd", the scheduled local calendar day
    public var startMinutes: Int?   // minutes since local midnight, 0...1439
    public var endMinutes: Int?
    public var tags: [String]
    public var link: URL?
    public var createdAt: Date

    /// An opaque identity token for the file's contents at the moment it
    /// was read (mtime, size, inode). This is the optimistic-concurrency
    /// token: the app and the MCP server both do read-modify-write on the
    /// whole file, so `TaskStore` re-checks it immediately before saving and
    /// refuses to write over a file someone else has touched since. `nil` if
    /// it couldn't be read. Compared only for equality — never parsed.
    public var signature: String?

    /// Raw frontmatter lines (between the `---` fences) exactly as read from
    /// disk, in original order — including comments, blank lines, and any
    /// key this app doesn't know about. Every rewrite (toggling done,
    /// editing via the sheet) goes through `TaskFile.setValue` so this
    /// content survives byte-for-byte except for the one line being
    /// changed. `nil` if the file had no parseable frontmatter block.
    public var rawFrontmatterLines: [String]?

    /// Everything after the closing `---` fence, verbatim — this is the
    /// task's description/notes, rendered as markdown so `[label](url)`
    /// and bare URLs become clickable.
    public var rawBody: String

    public init(
        url: URL,
        title: String,
        kind: TaskKind,
        isDone: Bool,
        dateString: String,
        startMinutes: Int?,
        endMinutes: Int?,
        tags: [String],
        link: URL?,
        createdAt: Date,
        signature: String? = nil,
        rawFrontmatterLines: [String]?,
        rawBody: String
    ) {
        self.url = url
        self.title = title
        self.kind = kind
        self.isDone = isDone
        self.dateString = dateString
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.tags = tags
        self.link = link
        self.createdAt = createdAt
        self.signature = signature
        self.rawFrontmatterLines = rawFrontmatterLines
        self.rawBody = rawBody
    }

    public var hasTime: Bool { startMinutes != nil }

    /// The description with any appended "## Enrichment log" section cut
    /// off. The log is machine-appended provenance that grows without
    /// bound; in a three-line row preview it would push the actual prep
    /// notes out of view, which is the opposite of what the row is for.
    ///
    /// The heading must be a whole line. An unanchored substring search
    /// also matched "### Enrichment log" (which contains it at offset one,
    /// so the preview truncated and left a dangling `#`) and any passing
    /// mention of the phrase in prose.
    public var bodyPreview: String {
        var kept: [String] = []
        for line in rawBody.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces) == TaskFile.enrichmentHeading { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }
}

public enum TaskFile {
    /// Keys this app understands. Anything else in a file's frontmatter is
    /// opaque to us and always passed through untouched. (`source` is
    /// written by the MCP server and rides along as unknown data here —
    /// see mcp-server/taskfile.js.)
    public static let knownKeys: Set<String> = [
        "title", "kind", "done", "date", "start", "end", "tags", "link", "created"
    ]

    public static let enrichmentHeading = "## Enrichment log"

    public static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Non-lenient by design: "2026-02-31" must parse as nil, not roll
    /// forward into March. mcp-server's `isDateString` matches this.
    ///
    /// `timeZone` is deliberately NOT assigned. An explicitly-set time zone
    /// is pinned at first use and stops tracking the system, so after the
    /// machine's zone changes (travel, a DST-rule update) this would keep
    /// bucketing days in the old zone while `Calendar.current` elsewhere in
    /// the app, and `dateStringOf` in the MCP server, both moved on.
    public static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.isLenient = false
        return f
    }()

    public static func todayString(_ date: Date = Date()) -> String {
        dateOnlyFormatter.string(from: date)
    }

    private static let dateShapeRegex = try! NSRegularExpression(
        pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"
    )

    /// True only for a well-formed *and* real "yyyy-MM-dd".
    ///
    /// The shape is checked explicitly before the formatter gets a look in:
    /// DateFormatter happily parses "2026-8-16" against "yyyy-MM-dd" even
    /// when non-lenient, but the JS side's regex requires zero-padding — so
    /// leaving it to the formatter alone let the app accept a date the MCP
    /// server would reject and silently reset to the creation day.
    public static func isDateString(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard dateShapeRegex.firstMatch(in: value, range: range) != nil else { return false }
        return dateOnlyFormatter.date(from: value) != nil
    }

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// "2026-08-10" -> "Aug 10". Shared by the Overdue badge and search
    /// results, wherever a task needs a compact date badge outside its own
    /// day view.
    public static func shortDateLabel(_ dateString: String) -> String {
        guard let date = dateOnlyFormatter.date(from: dateString) else { return dateString }
        return shortDateFormatter.string(from: date)
    }

    // MARK: - Parsing

    /// Parses a task file's raw text into a `TaskItem`. Never throws —
    /// malformed files degrade gracefully (title = filename) rather than
    /// being skipped or deleted.
    public static func parse(url: URL, contents: String, signature: String? = nil) -> TaskItem {
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        let attributes = try? url.resourceValues(forKeys: [.creationDateKey])

        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closingIndex = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else {
            // No frontmatter: whole file is body, fall back to filename title.
            let stem = url.deletingPathExtension().lastPathComponent
            let fallbackTitle = stem
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let createdAt = attributes?.creationDate ?? Date()
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
                signature: signature,
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
            ?? attributes?.creationDate
            ?? Date()

        let stem = url.deletingPathExtension().lastPathComponent
        let resolvedDate = dateRaw.flatMap { isDateString($0) ? $0 : nil }
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
            signature: signature,
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

    // MARK: - Time parsing

    // THE CANONICAL TIME GRAMMAR — kept identical to parseTimeToMinutes in
    // mcp-server/taskfile.js, and pinned by the shared fixtures. Exactly two
    // shapes are accepted; everything else is nil:
    //
    //   1. 24-hour "H:mm" / "HH:mm"  — hour 0–23, minute exactly two digits
    //   2. 12-hour "h[:mm] am|pm"    — hour 1–12, optional minutes, optional
    //                                  space, optional dots ("3pm", "3:30 p.m.")
    //
    // Frontmatter is always WRITTEN as shape 1 by both writers; shape 2
    // exists so a hand-typed or voice-derived time still lands correctly.
    //
    // Regex rather than DateFormatter on purpose: DateFormatter's leniency
    // and locale sensitivity are exactly what made this drift from the JS
    // side in the first place (it accepted "9:005" as 9:00, and rejected
    // "3pm" outright).
    private static let hourMinuteRegex = try! NSRegularExpression(
        pattern: "^([0-9]{1,2}):([0-9]{2})$"
    )
    private static let twelveHourRegex = try! NSRegularExpression(
        pattern: "^([0-9]{1,2})(?::([0-9]{2}))?\\s*([ap])\\.?\\s*m\\.?$",
        options: [.caseInsensitive]
    )

    public static func parseMinutes(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let full = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)

        if let match = hourMinuteRegex.firstMatch(in: trimmed, range: full) {
            guard let hour = intGroup(match, 1, in: trimmed),
                  let minute = intGroup(match, 2, in: trimmed),
                  hour <= 23, minute <= 59 else { return nil }
            return hour * 60 + minute
        }

        if let match = twelveHourRegex.firstMatch(in: trimmed, range: full) {
            guard let rawHour = intGroup(match, 1, in: trimmed) else { return nil }
            let minute = intGroup(match, 2, in: trimmed) ?? 0
            // 12-hour clock: only 1–12 is meaningful. "0am"/"13pm" are typos.
            guard (1...12).contains(rawHour), minute <= 59 else { return nil }
            guard let meridiem = stringGroup(match, 3, in: trimmed)?.lowercased() else { return nil }
            let hour = (rawHour % 12) + (meridiem == "p" ? 12 : 0)
            return hour * 60 + minute
        }

        return nil
    }

    private static func stringGroup(_ match: NSTextCheckingResult, _ index: Int, in string: String) -> String? {
        guard let range = Range(match.range(at: index), in: string) else { return nil }
        return String(string[range])
    }

    private static func intGroup(_ match: NSTextCheckingResult, _ index: Int, in string: String) -> Int? {
        stringGroup(match, index, in: string).flatMap(Int.init)
    }

    public static func formatMinutesHHmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    public static func formatMinutesDisplay(_ minutes: Int) -> String {
        let hour24 = minutes / 60
        let minute = minutes % 60
        let meridiem = hour24 < 12 ? "AM" : "PM"
        var hour12 = hour24 % 12
        if hour12 == 0 { hour12 = 12 }
        return String(format: "%d:%02d %@", hour12, minute, meridiem)
    }

    // MARK: - Mutation

    /// Finds the line for `key` (case-insensitive) and replaces its value in
    /// place; appends a new line just before the closing fence if the key
    /// isn't present; removes the line entirely if `value` is `nil`. Every
    /// other line — including ones this app doesn't understand — is left
    /// untouched, in its original position. This is the single mutation
    /// path used by every save, so the preserve-unknown-data guarantee
    /// holds everywhere, not just for `done`.
    /// Anything that would end a line, as far as either parser is concerned.
    /// Deliberately NOT all of Unicode's format category — that would catch
    /// zero-width joiners and break emoji, which titles are allowed to have.
    private static let lineBreakingCharacters: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: Unicode.Scalar(0x00)!...Unicode.Scalar(0x1F)!) // C0 controls
        set.insert(charactersIn: Unicode.Scalar(0x7F)!...Unicode.Scalar(0x9F)!) // DEL + C1
        set.insert(Unicode.Scalar(0x2028)!) // LINE SEPARATOR
        set.insert(Unicode.Scalar(0x2029)!) // PARAGRAPH SEPARATOR
        set.insert(Unicode.Scalar(0xFEFF)!) // ZERO WIDTH NO-BREAK SPACE / BOM
        return set
    }()

    /// Collapses anything that would break the one-key-per-line frontmatter
    /// grammar into a single space. Mirrors `sanitizeValue` in
    /// mcp-server/taskfile.js.
    ///
    /// A title containing a newline used to splice a second `---` fence into
    /// the middle of the frontmatter: every key below it fell into the body,
    /// so a timed, tagged meeting silently became an untitled task on today.
    public static func sanitizedValue(_ value: String) -> String {
        value
            .components(separatedBy: lineBreakingCharacters)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func setValue(_ value: String?, forKey key: String, in lines: [String]) -> [String] {
        let matches = lines.indices.filter { keyOf(lines[$0]) == key }

        guard let first = matches.first else {
            guard let value else { return lines }
            return lines + ["\(key): \(sanitizedValue(value))"]
        }

        // Rewrite the FIRST match and drop any later duplicates, because
        // `parse` above takes the LAST occurrence of a repeated key. With
        // first-write/last-read, a file that somehow grew two `done:` lines
        // could never be toggled: the write landed on line 1, the read came
        // from line 5, and the checkbox snapped straight back with no error.
        let duplicates = Set(matches.dropFirst())
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for index in lines.indices {
            if duplicates.contains(index) { continue }
            if index == first {
                guard let value else { continue }
                out.append("\(key): \(sanitizedValue(value))")
                continue
            }
            out.append(lines[index])
        }
        return out
    }

    /// Re-serializes a task with no edits at all. For any file that had
    /// frontmatter, the output must be byte-identical to what was read
    /// (line endings normalized) — the preserve-everything guarantee in its
    /// purest form, and what the conformance tests assert against.
    ///
    /// Note this is NOT the same as `serialize(task, isDone: task.isDone)`:
    /// that one rewrites the `done` line, so a file saying `done: yes`
    /// would come back canonicalized to `done: false`.
    public static func serializeUnchanged(_ task: TaskItem) -> String {
        applyingEdits(to: task) { $0 }
    }

    /// Re-serializes a task, flipping only the `done` value.
    public static func serialize(_ task: TaskItem, isDone: Bool) -> String {
        applyingEdits(to: task) { lines in
            setValue(String(isDone), forKey: "done", in: lines)
        }
    }

    /// Re-serializes a task after a full edit from the New/Edit sheet. Only
    /// the fields the sheet actually exposes are touched; comments, blank
    /// lines, and unknown keys survive exactly as they were.
    public static func serializeEdit(
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
    public static func newFileContents(
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
        // Every value goes through sanitizedValue for the same reason
        // setValue does: a newline here splices a second `---` fence into the
        // block and the file is born corrupt. The body is exempt — it lives
        // below the fence, where newlines are the whole point.
        var lines: [String] = []
        lines.append("title: \(sanitizedValue(title))")
        if kind == .meeting { lines.append("kind: meeting") }
        lines.append("done: false")
        lines.append("date: \(sanitizedValue(dateString))")
        if let startMinutes { lines.append("start: \(formatMinutesHHmm(startMinutes))") }
        if let endMinutes { lines.append("end: \(formatMinutesHHmm(endMinutes))") }
        let cleanTags = tags.map(sanitizedValue).filter { !$0.isEmpty }
        if !cleanTags.isEmpty { lines.append("tags: \(cleanTags.joined(separator: ", "))") }
        let cleanLink = sanitizedValue(link)
        if !cleanLink.isEmpty { lines.append("link: \(cleanLink)") }
        lines.append("created: \(isoFormatter.string(from: createdAt))")
        let trimmedBody = body.isEmpty ? "" : "\n\(body)"
        return "---\n" + lines.joined(separator: "\n") + "\n---\n" + trimmedBody
    }

    /// Builds a stable, human-readable filename from the creation instant.
    /// Filenames are never changed after creation — rescheduling a task
    /// only ever touches its `date`/`start`/`end` frontmatter.
    public static func newFilename(title: String, createdAt: Date) -> String {
        let stampFormatter = DateFormatter()
        stampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        stampFormatter.timeZone = TimeZone(identifier: "UTC")
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = stampFormatter.string(from: createdAt)
        return "\(stamp)-\(slug(for: title)).md"
    }

    /// Lowercased, non-alphanumerics collapsed to single dashes, trimmed,
    /// capped at 40 characters. Mirrors `slugify` in mcp-server/taskfile.js.
    ///
    /// ASCII-only on purpose: the JS side tests `/[a-z0-9]/`, so treating
    /// "é" or "日" as a letter here (which `Character.isLetter` does) would
    /// make the two sides generate different filenames for the same title.
    public static func slug(for title: String) -> String {
        let collapsed = title
            .lowercased()
            .map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }
            .reduce(into: "") { result, char in
                if char == "-" && result.hasSuffix("-") { return }
                result.append(char)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        return collapsed.isEmpty ? "task" : String(collapsed.prefix(40))
    }
}
