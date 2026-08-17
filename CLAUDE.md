# Working on this project

A local-only macOS to-do app. Every task is a markdown file in `Tasks/`.
There is no database, no server, no account. `README.md` documents the app
and the file format; this file is the rules for changing the code.

## The one thing to understand first

**The file format is implemented twice, in two languages, and both run at
the same time against the same folder.**

| | |
|---|---|
| `Sources/ToDoCore/TaskItem.swift` | Swift. The app. |
| `mcp-server/taskfile.js` | JavaScript. The MCP server Claude Desktop talks to. |

They are not layered — they are peers. Two processes, two parsers, two
writers, one directory. When they disagree about what a file means, nothing
crashes and nothing logs; the app just quietly shows you something different
from what Claude sees. Every drift bug found so far has been of that shape:
`start: 3pm` was 3:00 PM to one and *unscheduled* to the other; a title
containing a newline turned a timed meeting into an untitled task on today.

`Tests/fixtures/cases.json` is the shared specification. Both suites assert
against those exact fixtures.

**If you change how either side parses, writes, or validates anything:**

1. Change it in **both** languages.
2. Add a case to `Tests/fixtures/cases.json`.
3. Run **both** suites.

```sh
swift test                      # from the project root
cd mcp-server && npm test
./build.sh                      # runs both, then builds the app
```

Every fixture tagged `regression` is a real bug that shipped. Read them
before touching the parser — they are the cheapest available description of
where this format is sharp.

## Invariants — do not break these without saying so

- **Unknown frontmatter keys, comments, and blank lines survive every
  write, byte for byte.** The app doesn't know about `source:`; the server
  doesn't know what the app might add next. Both pass through anything they
  don't recognise. All mutation goes through `setValue` / `TaskFile.setValue`
  for this reason — never rebuild a frontmatter block from parsed fields.
- **Filenames never change after creation.** Rescheduling edits the `date:`
  field. Renaming a file orphans it from anything referencing its id.
- **Deleting means macOS Trash**, never `unlink`. It's the user's calendar.
- **Frontmatter values are single-line.** Anything user- or LLM-supplied goes
  through `sanitizeValue` / `TaskFile.sanitizedValue` before being written; a
  newline in a value splices a second `---` fence and corrupts the file.
- **Both writers check the file hasn't changed before writing.** Each
  rewrites the whole file from a snapshot, so without the check whichever
  saves second erases the other. Refusing to write is always better than
  clobbering — and a *failed* write must never lose what the user typed.
- **A malformed file degrades; it is never skipped or destroyed.** Bad date,
  unparseable time, no frontmatter at all — it still shows up as a task.
- **Times are written as 24-hour `HH:mm`.** Both parsers accept `3pm` on
  input; neither writes it.
- **Days are local, never UTC.** Bucketing, `dateStringOf`, `todayString`,
  enrichment timestamps. The only UTC thing is the filename stamp.

## Never fabricate task content

When building tasks from a calendar or any other source: if an event has no
description, the body is empty. Do not invent talking points, agendas, or
attendees. One factual line derived from real data (`With: Name (Company)`)
is the ceiling. Tags come from real signal — an attendee's email domain, not
a guess at the project. `README.md` has the full calendar mapping rules.

This matters more than it sounds: the user reads these notes minutes before
walking into the meeting, and cannot tell invented context from real.

## Layout

```
Sources/ToDoCore/     model + file format. Foundation only, no UI. Testable.
Sources/ToDoApp/      SwiftUI app. TaskStore.swift owns all file I/O.
Tests/fixtures/       the shared spec — read by BOTH languages
Tests/ToDoCoreTests/  Swift half of the conformance suite
mcp-server/           the MCP server; taskfile.js is TaskItem.swift's twin
Tasks/                the user's real data. Not in git. Don't test against it.
```

Tests run against temp directories. Never point a test, a script, or a
manual experiment at `Tasks/` — those are real meetings.

## Environment notes

- macOS 13+, `swift-tools-version:5.9`. Building needs **full Xcode**, not
  just the Command Line Tools — XCTest ships with Xcode.
- `./build.sh` tests, builds, assembles `ToDo.app`, and ad-hoc signs it.
  `SKIP_TESTS=1` to skip the suites.
- The MCP server finds `Tasks/` via a pointer file the app writes on launch
  (`mcp-server/tasksdir.js`). It will refuse to run rather than create a
  folder it isn't sure about — an empty decoy folder is how the two writers
  silently diverged before. `TODO_APP_TASKS_DIR` overrides.
- After changing MCP server code, reinstall the extension in Claude Desktop;
  it copies the folder rather than running it in place.

## Style

Match what's there. Comments explain *why*, especially where the code looks
odd — most of the odd-looking code is odd because the obvious version had a
bug, and the comment is the only record of it. If you fix something subtle,
leave a note saying what went wrong, not just what the code now does.
