# To-Do

A local-only macOS run-sheet / to-do app. No account, no cloud, no App
Store, no code signing — the whole app is this Finder folder, and every
task or meeting is a plain text file inside `Tasks/`. The point: you (or
Claude Code) can manage the whole day by just reading and editing files.

## How it's laid out

```
To-Do App/
├── ToDo.app           ← the built, runnable app (double-click it)
├── Tasks/             ← one .md file per task/meeting — the entire database
├── Sources/
│   ├── ToDoCore/      ← the task model + file format (no UI, unit-tested)
│   └── ToDoApp/       ← the SwiftUI app
├── Tests/
│   ├── fixtures/      ← shared conformance fixtures (Swift AND JS read these)
│   └── ToDoCoreTests/
├── mcp-server/        ← local MCP server over the same Tasks/ folder
├── Package.swift
├── build.sh           ← rebuild ToDo.app after changing source
└── Info.plist
```

`ToDo.app` always looks for a `Tasks` folder **next to itself**. Move this
whole folder anywhere and it keeps working — app and data travel together.

## What the app looks like

One day at a time, run-sheet style — a flat list sorted by time, not a
calendar grid:

- **Overdue** — anything left undone on a day that's already passed,
  surfaced at the top only when you're looking at today, until you finish
  it, reschedule it, or delete it.
- **Schedule** — timed tasks and meetings, sorted by start time. Two items
  that overlap (double-booked meetings happen) are both flagged with a
  plain "Overlaps another item" warning rather than squeezed into columns
  or otherwise laid out specially.
- **Unscheduled** — a plain checklist underneath for tasks that don't have
  a time (most day-to-day to-dos).
- Day navigation (‹ Today › ) at the top, with a search icon next to it —
  see "Search" below.

### Menu bar glance

The app also lives in the menu bar (a checklist icon) so you can see
what's next without switching windows: what's happening **now** (if
anything), what's coming up next today with a time-until, a short list of
whatever else is left today, and one-click links. Closing the main window
does not quit the app — it keeps running in the menu bar; "Quit" in the
menu bar popover is the real way to close it.

### Search

The magnifying-glass icon next to the day title searches titles, tags,
and notes across **every** day, not just the one on screen. Tapping a
result jumps you to that day with the item's editor already open.

### Follow-up tasks

From a task or meeting's edit sheet, "Follow-up" opens a new task
prefilled with a title, the source's tags, and one line in the body —
`**Follow-up from:** <source title> — <source date>` — noting where it
came from. That's a plain body line, not a frontmatter field, so it's
just as visible reading the raw file as it is in the app; add one by
hand the same way if you're creating a follow-up directly as a file.

## The task file format

Each task or meeting is a `.md` file in `Tasks/`:

```markdown
---
title: Crimsafe x Aircall x BAC Catchup
kind: meeting
date: 2026-08-10
start: 10:00
end: 11:00
done: false
tags: external, crimsafe
link: https://meet.google.com/iey-npcb-uct
created: 2026-08-10T22:17:02Z
---

Items to discuss (for reference):
- Automatic contact creation from Aircall - what this will look like in HubSpot
- Phone number formatting - inconsistent across HubSpot, will impact calls and SMS
```

Fields the app understands:

| Key | Meaning |
|---|---|
| `title` | Required. |
| `kind` | `task` (default) or `meeting` — purely visual (meetings get a green tint on their row). |
| `date` | `yyyy-MM-dd`, the scheduled day. Defaults to the file's creation day if omitted. |
| `start`, `end` | A time (see below). Omit both for an unscheduled task (shows in the Unscheduled checklist instead of the Schedule section). `end` is optional even when `start` is set. |
| `done` | `true`/`false`. Anything other than exactly `true` reads as false. |
| `tags` | Comma-separated. Shown as pills; use for sorting/filtering by eye (e.g. company name, project, `internal`/`external`, `focus`). |
| `link` | One URL — the primary link (Zoom/Meet/call link). Rendered as a one-click button on the row. |
| `created` | ISO-8601, set once at creation, never changed. |
| `source` | Optional provenance key written by the MCP server (e.g. `gcal:<event_id>`) so a re-sync updates the existing file instead of creating a duplicate. Invisible in the app, which passes it through untouched. |

### Times and dates

Both `start` and `end` accept exactly two shapes, and so does anything you
say to the MCP server:

- **24-hour** — `9:00`, `09:00`, `15:30`. Minutes must be two digits.
- **12-hour** — `3pm`, `3 PM`, `3:30pm`, `3:30 p.m.`. Hour must be 1–12.

Anything else (`half nine`, `9:5`, `25:00`, `noon`) is treated as *no time*,
which quietly turns a meeting into an unscheduled to-do — so if something
lands in the wrong section, check the time format first. Both writers always
save back as 24-hour `HH:mm`.

`date` must be a real `yyyy-MM-dd`. An impossible one like `2026-02-31` is
rejected rather than rolled forward, and the task falls back to its creation
day.

Everything else — the body underneath the closing `---`, comments
(`# ...`), and any key this app doesn't recognize — is preserved
byte-for-byte on every save, including edits made through the app's UI.
**Filenames never change after creation**; reschedule a task by editing its
`date`/`start`/`end` fields, not by renaming the file.

Both writers rewrite the whole file from a snapshot taken when they read
it, so both check the file's modification time immediately before saving.
If Claude rewrites a file while its edit sheet happens to be open, Save
refuses and tells you, rather than silently overwriting Claude's change —
reopen the item and redo the edit. The MCP server does the same in the
other direction and reports that the task changed underneath it. Nothing is
lost either way; the second writer just has to look again first.

**The body is the description** — rendered as markdown, so `[label](url)`
links (slides, docs, tickets) and bare `https://…` URLs are clickable.
This is where meeting prep notes go.

The app watches `Tasks/` with a kernel directory watch, so a file written
by Claude, Finder, or the MCP server shows up essentially instantly. An
in-place edit by a text editor (which doesn't touch the directory itself)
is caught by a 2-second backstop poll. Either way, no restart needed.

## For Claude Code: turning a calendar into a run sheet

When asked to build or update a day's run sheet from Google Calendar (or
similar), pull the day's events and write one file per event, following
these mapping rules:

- **Bucket by the event's local calendar day**, not the query window —
  a `list_events` UTC range straddles local midnight, so always convert
  each event's own start time to local before deciding which `date:` it
  belongs on.
- **All-day events**: skip ones marked `transparency: transparent`
  (holidays, culture reminders — non-blocking, not real agenda items).
  An opaque (busy) all-day event becomes an unscheduled task for that day.
- **Declined-by-the-user events**: Google normally excludes these from
  `list_events` already; no special handling needed unless one slips
  through, in which case skip it.
- **Link**: check in order — (1) `conferenceUrl` (native Google Meet/Zoom
  integration); (2) `location`, if it's itself a bare URL (booking tools
  like Chili Piper often dump a raw Zoom link — e.g.
  `https://x.zoom.us/j/...` — straight into `location` instead of using
  `conferenceUrl`); (3) the first `zoom.us`/`meet.google.com`/
  `teams.microsoft.com` URL found in `description` text. Only if none of
  those hit, and `location` is a physical place/room, put it in the body
  as a plain note instead of a link.
- **Description / prep notes — never fabricate.** If the calendar event
  has a real `description`, clean up its HTML into markdown (lists,
  links) and use that as the body — this is the actual "what to talk
  about" content. If it has `attachments` (a doc/deck), add them as
  markdown links in the body. If an event has **neither**, don't invent
  talking points — at most add one factual line like `With: Name
  (Company)` derived from real attendee data, or leave the body empty.
- **Tags**: derive from real signal only — e.g. `internal` when every
  attendee is on the home domain, or the external company's name from an
  outside attendee's email domain. Don't guess a project/category tag
  that isn't evidenced somewhere in the event.
- Titles from calendar events sometimes have trailing whitespace or emoji
  — trim whitespace, emoji are fine to keep.

To add a one-off task (not from a calendar), just write a `.md` file
following the format above — `kind` and `start`/`end` are optional. To
complete something, flip `done:` to `true`. To remove it, delete the file
(or move it to Trash).

## Voice / chat control via MCP

`mcp-server/` is a local MCP server exposing the same `Tasks/` folder as a
set of tools (add/update/search/complete/follow-up/delete) so Claude
Desktop can act on your run sheet live during a conversation — see
`mcp-server/README.md` for setup and the one open question (whether voice
mode specifically calls connector tools, not just text chat).

## Building / running

```sh
./build.sh       # runs the tests, then builds ToDo.app
open "ToDo.app"
```

Requires macOS 13+ and Xcode Command Line Tools. The app is unsigned
(ad-hoc signed locally by `build.sh` so macOS will run it). Since it's
built locally rather than downloaded, it isn't quarantined, so it should
just open normally.

`SKIP_TESTS=1 ./build.sh` builds without testing first.

## Tests, and why they exist

The task file format is implemented **twice** — `Sources/ToDoCore/TaskItem.swift`
in Swift and `mcp-server/taskfile.js` in JavaScript — because the app and
the MCP server are separate processes that both read and write `Tasks/`.
Two independent implementations of one format will drift, and drift here is
nasty: it doesn't crash, it just means the app and Claude quietly disagree
about what a file says. (This is not hypothetical. `start: 3pm` used to
parse as 3:00 PM for Claude and as *no time at all* for the app, putting the
same meeting in two different sections.)

`Tests/fixtures/cases.json` is the shared source of truth: time parsing,
date validation, filename slugs, and a set of awkward `.md` files with the
expected result for each. Both suites read those exact fixtures:

```sh
swift test                    # Swift side
cd mcp-server && npm test     # JavaScript side
```

**If you change how either side parses or writes files, add a case to
`cases.json` and run both suites.** That file is also the best short
description of the format's edge cases — every entry marked `regression` is
a bug that actually shipped.
