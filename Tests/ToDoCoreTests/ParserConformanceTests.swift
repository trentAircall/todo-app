import XCTest
@testable import ToDoCore

/// The Swift half of the cross-language conformance suite.
///
/// mcp-server/test/conformance.test.js is the other half, and both read the
/// SAME fixtures from Tests/fixtures/. That is the whole point: the task file
/// format is implemented twice — once here, once in JavaScript — because the
/// app and the MCP server both read and write the same folder. Agreement
/// between the two is checked, not assumed.
///
/// Run with:  swift test
final class ParserConformanceTests: XCTestCase {

    // MARK: - Fixture loading

    /// Located relative to this source file rather than through a resource
    /// bundle, because the Node suite reads the identical directory.
    private static let fixturesURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/ToDoCoreTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("fixtures", isDirectory: true)

    private struct Cases: Decodable {
        struct TimeCase: Decodable {
            let input: String
            let expected: Int?
            let regression: String?
        }
        struct DateCase: Decodable {
            let input: String
            let expected: Bool
            let regression: String?
        }
        struct SlugCase: Decodable {
            let input: String
            let expected: String
            let regression: String?
        }
        struct FileCase: Decodable {
            struct Expected: Decodable {
                let title: String
                let kind: String
                let done: Bool
                let dateString: String?
                let startMinutes: Int?
                let endMinutes: Int?
                let tags: [String]
                let link: String?
                let hasFrontmatter: Bool
                let body: String?
            }
            let name: String
            let file: String
            let expected: Expected
        }
        let times: [TimeCase]
        let dates: [DateCase]
        let slugs: [SlugCase]
        let files: [FileCase]
    }

    private lazy var cases: Cases = {
        let url = Self.fixturesURL.appendingPathComponent("cases.json")
        guard let data = try? Data(contentsOf: url) else {
            fatalError("Missing shared fixtures at \(url.path)")
        }
        do {
            return try JSONDecoder().decode(Cases.self, from: data)
        } catch {
            fatalError("Could not decode \(url.path): \(error)")
        }
    }()

    private func fixtureFile(_ name: String) throws -> (url: URL, contents: String) {
        let url = Self.fixturesURL
            .appendingPathComponent("files", isDirectory: true)
            .appendingPathComponent(name)
        return (url, try String(contentsOf: url, encoding: .utf8))
    }

    private func note(_ regression: String?) -> String {
        guard let regression else { return "" }
        return " — regression: \(regression)"
    }

    // MARK: - Shared fixtures

    func testTimeGrammarMatchesSharedFixtures() {
        for testCase in cases.times {
            XCTAssertEqual(
                TaskFile.parseMinutes(testCase.input),
                testCase.expected,
                "parseMinutes(\(testCase.input.debugDescription))\(note(testCase.regression))"
            )
        }
    }

    func testDateValidationMatchesSharedFixtures() {
        for testCase in cases.dates {
            XCTAssertEqual(
                TaskFile.isDateString(testCase.input),
                testCase.expected,
                "isDateString(\(testCase.input.debugDescription))\(note(testCase.regression))"
            )
        }
    }

    func testSlugsMatchSharedFixtures() {
        for testCase in cases.slugs {
            XCTAssertEqual(
                TaskFile.slug(for: testCase.input),
                testCase.expected,
                "slug(for: \(testCase.input.debugDescription))\(note(testCase.regression))"
            )
        }
    }

    func testFileParsingMatchesSharedFixtures() throws {
        for testCase in cases.files {
            let (url, contents) = try fixtureFile(testCase.file)
            let task = TaskFile.parse(url: url, contents: contents)
            let want = testCase.expected
            let where_ = "\(testCase.name) (\(testCase.file))"

            XCTAssertEqual(task.title, want.title, "\(where_): title")
            XCTAssertEqual(task.kind.rawValue, want.kind, "\(where_): kind")
            XCTAssertEqual(task.isDone, want.done, "\(where_): done")
            XCTAssertEqual(task.startMinutes, want.startMinutes, "\(where_): startMinutes")
            XCTAssertEqual(task.endMinutes, want.endMinutes, "\(where_): endMinutes")
            XCTAssertEqual(task.tags, want.tags, "\(where_): tags")
            XCTAssertEqual(task.rawFrontmatterLines != nil, want.hasFrontmatter, "\(where_): hasFrontmatter")

            // Fields a fixture may legitimately omit: `dateString` is derived
            // from the file's creation time when the frontmatter date is
            // missing or invalid, and `link` isn't meaningful for every case.
            if let wantDate = want.dateString {
                XCTAssertEqual(task.dateString, wantDate, "\(where_): dateString")
            }
            if let wantBody = want.body {
                XCTAssertEqual(task.rawBody, wantBody, "\(where_): body")
            }
            XCTAssertEqual(task.link?.absoluteString, want.link, "\(where_): link")
        }
    }

    // MARK: - The preserve-unknown-data guarantee

    func testIdentityEditRoundTripsByteForByte() throws {
        for testCase in cases.files where testCase.expected.hasFrontmatter {
            let (url, contents) = try fixtureFile(testCase.file)
            let task = TaskFile.parse(url: url, contents: contents)
            // Must be serializeUnchanged, not serialize(isDone: task.isDone):
            // the latter rewrites the `done` line, which canonicalizes a
            // file saying `done: yes` into `done: false` and so isn't an
            // identity operation at all.
            let out = TaskFile.serializeUnchanged(task)
            XCTAssertEqual(
                out,
                contents.replacingOccurrences(of: "\r\n", with: "\n"),
                "\(testCase.name): identity edit should be a no-op (line endings normalized)"
            )
        }
    }

    func testEditingOneKeyLeavesCommentsAndUnknownKeysInPlace() throws {
        let (url, contents) = try fixtureFile("unknown-keys.md")
        let task = TaskFile.parse(url: url, contents: contents)
        let out = TaskFile.serialize(task, isDone: false)

        XCTAssertTrue(out.contains("# This comment must survive a round-trip untouched."))
        XCTAssertTrue(out.contains("source: gcal:abc123"), "a key only the MCP server knows")
        XCTAssertTrue(out.contains("x-experimental: something neither side knows"), "a key neither side knows")
        XCTAssertTrue(out.contains("done: false"), "the one key we asked to change")
        XCTAssertFalse(out.contains("done: true"))

        XCTAssertEqual(
            out.components(separatedBy: "\n").count,
            contents.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").count,
            "no lines added or dropped"
        )
    }

    func testFullEditPreservesUnknownKeys() throws {
        let (url, contents) = try fixtureFile("unknown-keys.md")
        let task = TaskFile.parse(url: url, contents: contents)
        let out = TaskFile.serializeEdit(
            task,
            title: "Renamed",
            kind: .meeting,
            dateString: "2026-09-01",
            startMinutes: 600,
            endMinutes: 660,
            tags: ["a", "b"],
            link: "https://example.com",
            body: "\nNew body.\n"
        )

        XCTAssertTrue(out.contains("title: Renamed"))
        XCTAssertTrue(out.contains("kind: meeting"))
        XCTAssertTrue(out.contains("date: 2026-09-01"))
        XCTAssertTrue(out.contains("start: 10:00"))
        XCTAssertTrue(out.contains("end: 11:00"))
        XCTAssertTrue(out.contains("tags: a, b"))
        XCTAssertTrue(out.contains("link: https://example.com"))
        XCTAssertTrue(out.contains("New body."))
        // The whole point: a full edit through the sheet still can't eat
        // frontmatter this app doesn't understand.
        XCTAssertTrue(out.contains("source: gcal:abc123"))
        XCTAssertTrue(out.contains("x-experimental: something neither side knows"))
        XCTAssertTrue(out.contains("# This comment must survive a round-trip untouched."))
    }

    func testRemovingAKeyDeletesOnlyThatLine() throws {
        let (url, contents) = try fixtureFile("full-meeting.md")
        let task = TaskFile.parse(url: url, contents: contents)
        let out = TaskFile.serializeEdit(
            task,
            title: task.title,
            kind: task.kind,
            dateString: task.dateString,
            startMinutes: task.startMinutes,
            endMinutes: task.endMinutes,
            tags: task.tags,
            link: "",                    // clearing the link
            body: task.rawBody
        )
        XCTAssertFalse(out.contains("link:"))
        XCTAssertTrue(out.contains("tags: external, crimsafe"))
        XCTAssertEqual(
            out.components(separatedBy: "\n").count,
            contents.components(separatedBy: "\n").count - 1
        )
    }

    func testFileWithoutFrontmatterGainsOneWithoutLosingItsContent() throws {
        let (url, contents) = try fixtureFile("no-frontmatter.md")
        let task = TaskFile.parse(url: url, contents: contents)
        XCTAssertNil(task.rawFrontmatterLines)

        let out = TaskFile.serialize(task, isDone: true)
        XCTAssertTrue(out.hasPrefix("---\n"))
        XCTAssertTrue(out.contains("done: true"))
        XCTAssertTrue(out.contains("created: "), "a synthesized block still records creation time")
        XCTAssertTrue(out.contains("Just some notes someone dropped in here."), "original text survives as the body")
        XCTAssertTrue(out.contains("No fences at all."))
    }

    // MARK: - Round-trip through creation

    func testNewFileContentsParsesBackToWhatWentIn() {
        let createdAt = Date(timeIntervalSince1970: 1_786_400_222) // 2026-08-10T22:17:02Z
        let contents = TaskFile.newFileContents(
            title: "Prep for Judith",
            kind: .meeting,
            dateString: "2026-08-20",
            startMinutes: 9 * 60 + 30,
            endMinutes: 10 * 60,
            tags: ["external", "airtasker"],
            link: "https://meet.google.com/abc-defg-hij",
            body: "Some notes.",
            createdAt: createdAt
        )
        let url = URL(fileURLWithPath: "/tmp/20260101-000000-prep-for-judith.md")
        let task = TaskFile.parse(url: url, contents: contents)

        XCTAssertEqual(task.title, "Prep for Judith")
        XCTAssertEqual(task.kind, .meeting)
        XCTAssertFalse(task.isDone)
        XCTAssertEqual(task.dateString, "2026-08-20")
        XCTAssertEqual(task.startMinutes, 570)
        XCTAssertEqual(task.endMinutes, 600)
        XCTAssertEqual(task.tags, ["external", "airtasker"])
        XCTAssertEqual(task.link?.absoluteString, "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(task.createdAt.timeIntervalSince1970, createdAt.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertTrue(task.rawBody.contains("Some notes."))
    }

    func testFilenamesAreStableAndTimezoneIndependent() {
        let at = Date(timeIntervalSince1970: 1_786_400_222) // 2026-08-10T22:17:02Z
        XCTAssertEqual(
            TaskFile.newFilename(title: "Crimsafe x Aircall Catchup", createdAt: at),
            "20260810-221702-crimsafe-x-aircall-catchup.md"
        )
        XCTAssertEqual(TaskFile.newFilename(title: "!!!", createdAt: at), "20260810-221702-task.md")
    }

    func testFormattingRoundTripsThroughParsing() {
        for minutes in stride(from: 0, through: 1439, by: 7) {
            XCTAssertEqual(
                TaskFile.parseMinutes(TaskFile.formatMinutesHHmm(minutes)),
                minutes,
                "HH:mm round-trip failed for \(minutes)"
            )
            XCTAssertEqual(
                TaskFile.parseMinutes(TaskFile.formatMinutesDisplay(minutes)),
                minutes,
                "display round-trip failed for \(minutes) (\(TaskFile.formatMinutesDisplay(minutes)))"
            )
        }
    }

    // MARK: - Body preview

    func testBodyPreviewStopsAtTheEnrichmentLog() {
        let body = "Real prep notes.\n\n## Enrichment log\n- 2026-08-16 01:00: Drive doc linked\n"
        let task = TaskItem(
            url: URL(fileURLWithPath: "/tmp/x.md"),
            title: "x", kind: .task, isDone: false, dateString: "2026-08-16",
            startMinutes: nil, endMinutes: nil, tags: [], link: nil,
            createdAt: Date(), rawFrontmatterLines: [], rawBody: body
        )
        // Everything up to but not including the heading's own line. The
        // blank line between the notes and the heading is kept; the newline
        // that separated it FROM the heading is not, because that separator
        // belonged to the line being dropped.
        XCTAssertEqual(task.bodyPreview, "Real prep notes.\n")
        XCTAssertFalse(task.bodyPreview.contains("Drive doc linked"))

        // A body with no log is passed through untouched.
        var plain = task
        plain.rawBody = "Just notes."
        XCTAssertEqual(plain.bodyPreview, "Just notes.")

        // The heading must be a whole line: an h3 that merely contains the
        // phrase, or a passing mention in prose, must not truncate anything.
        var h3 = task
        h3.rawBody = "### Enrichment log\nstill notes"
        XCTAssertEqual(h3.bodyPreview, "### Enrichment log\nstill notes")

        var prose = task
        prose.rawBody = "See the ## Enrichment log below for sources."
        XCTAssertEqual(prose.bodyPreview, "See the ## Enrichment log below for sources.")
    }

    // MARK: - Frontmatter injection

    func testANewlineInAValueCannotBreakOutOfItsLine() {
        // Regression: a title containing "\n---" spliced a second fence into
        // the frontmatter. Every key below it fell into the body, so a timed,
        // tagged meeting silently became an untitled task on today.
        let hostile = [
            "Catchup\n---\nrogue: injected",
            "Catchup\r\ndate: 1999-01-01",
            "Catchup\u{2028}date: 1999-01-01",
            "Catchup\tand a tab",
        ]
        for title in hostile {
            let line = TaskFile.setValue(title, forKey: "title", in: [])[0]
            XCTAssertEqual(
                line.components(separatedBy: "\n").count, 1,
                "produced multiple lines for \(title.debugDescription)"
            )
            XCTAssertFalse(line.contains("\r"))
            XCTAssertFalse(line.contains("\u{2028}"))
        }
    }

    func testAnInjectedTitleCannotChangeHowTheFileParses() {
        let contents = TaskFile.newFileContents(
            title: "Catchup\n---\nrogue: injected",
            kind: .meeting,
            dateString: "2026-09-01",
            startMinutes: 600,
            endMinutes: 660,
            tags: ["external\n---"],
            link: "",
            body: "Prep notes.",
            createdAt: Date()
        )
        let task = TaskFile.parse(url: URL(fileURLWithPath: "/tmp/injected.md"), contents: contents)
        XCTAssertEqual(task.kind, .meeting, "still a meeting")
        XCTAssertEqual(task.dateString, "2026-09-01", "still on the requested day")
        XCTAssertEqual(task.startMinutes, 600, "still timed")

        let fences = contents.components(separatedBy: "\n").filter { $0 == "---" }
        XCTAssertEqual(fences.count, 2, "exactly two fences")
    }

    func testSanitizedValueCollapsesRatherThanDeletes() {
        XCTAssertEqual(TaskFile.sanitizedValue("Catchup\n---"), "Catchup ---")
        XCTAssertEqual(TaskFile.sanitizedValue("  spaced   out  "), "spaced out")
        XCTAssertEqual(TaskFile.sanitizedValue("Ünïcödé stays"), "Ünïcödé stays", "non-ASCII text is not mangled")
        XCTAssertEqual(TaskFile.sanitizedValue("emoji 👍 stays"), "emoji 👍 stays")
    }

    // MARK: - Duplicate keys

    func testWritingAKeyRemovesLaterDuplicates() throws {
        // Regression: parse takes the LAST occurrence, setValue rewrote the
        // FIRST. A file with two `done:` lines could never be toggled — the
        // write landed on line 1, the read came from line 5, and the
        // checkbox snapped straight back with no error.
        let out = TaskFile.setValue("false", forKey: "done", in: ["done: false", "title: X", "done: true"])
        XCTAssertEqual(out, ["done: false", "title: X"])

        let removed = TaskFile.setValue(nil, forKey: "start", in: ["start: 09:00", "x: 1", "start: 10:00"])
        XCTAssertEqual(removed, ["x: 1"])
    }

    func testADuplicatedKeyCanActuallyBeToggled() throws {
        let (url, contents) = try fixtureFile("duplicate-keys.md")
        let task = TaskFile.parse(url: url, contents: contents)
        XCTAssertTrue(task.isDone, "the last occurrence is what the parser sees")

        let written = TaskFile.serialize(task, isDone: false)
        let reparsed = TaskFile.parse(url: url, contents: written)
        XCTAssertFalse(reparsed.isDone, "un-ticking it must actually stick")
    }

    // MARK: - Overlap detection

    func testOverlapDetection() {
        func item(_ name: String, _ start: Int?, _ end: Int?) -> TaskItem {
            TaskItem(
                url: URL(fileURLWithPath: "/tmp/\(name).md"),
                title: name, kind: .meeting, isDone: false, dateString: "2026-08-20",
                startMinutes: start, endMinutes: end, tags: [], link: nil,
                createdAt: Date(), rawFrontmatterLines: [], rawBody: ""
            )
        }

        let overlapping = TimelineLayout.overlappingTaskIDs([
            item("a", 600, 660),
            item("b", 630, 690),
            item("c", 700, 730),
        ])
        XCTAssertEqual(Set(overlapping.map { $0.lastPathComponent }), ["a.md", "b.md"])

        // Back-to-back is not a clash.
        XCTAssertTrue(TimelineLayout.overlappingTaskIDs([
            item("a", 600, 660),
            item("b", 660, 720),
        ]).isEmpty)

        // Untimed items never clash.
        XCTAssertTrue(TimelineLayout.overlappingTaskIDs([
            item("a", nil, nil),
            item("b", nil, nil),
        ]).isEmpty)
    }
}
