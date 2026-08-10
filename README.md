# To-Do

A local-only macOS run-sheet / to-do app. No account, no cloud, no App
Store, no code signing — the whole app is this Finder folder, and every
task or meeting is a plain text file inside `Tasks/`. The point: you (or
Claude Code) can manage the whole day by just reading and editing files.

## How it's laid out

```
To-Do App/
├── ToDo.app          ← the built, runnable app (double-click it)
├── Tasks/            ← one .md file per task/meeting — the entire database
├── Sources/ToDoApp/  ← Swift source
├── Package.swift
├── build.sh          ← rebuild ToDo.app after changing source
└── Info.plist
```

`ToDo.app` always looks for a `Tasks` folder **next to itself**. Move this
whole folder anywhere and it keeps working — app and data travel together.

## What the app looks like

One day at a time, run-sheet style:

- **Timeline** — a calendar-style hour axis (7 AM–7 PM by default, expands
  automatically if something is scheduled earlier/later) showing every
  timed task or meeting as a positioned, sized block. Overlapping items
  (double-booked meetings happen) are split into side-by-side columns
  rather than drawn on top of each other.
- **Unscheduled** — a plain checklist underneath for tasks that don't have
  a time (most day-to-day to-dos).
- Day navigation (‹ Today › ) at the top; a live red line shows the
  current time on today's timeline.

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
| `kind` | `task` (default) or `meeting` — purely visual (meetings get a blue tint on the timeline). |
| `date` | `yyyy-MM-dd`, the scheduled day. Defaults to the file's creation day if omitted. |
| `start`, `end` | `HH:mm`, 24h. Omit both for an unscheduled task (shows in the checklist instead of the timeline). `end` is optional even when `start` is set. |
| `done` | `true`/`false`. |
| `tags` | Comma-separated. Shown as pills; use for sorting/filtering by eye (e.g. company name, project, `internal`/`external`, `focus`). |
| `link` | One URL — the primary link (Zoom/Meet/call link). Rendered as a one-click button on the row. |
| `created` | ISO-8601, set once at creation, never changed. |

Everything else — the body underneath the closing `---`, comments
(`# ...`), and any key this app doesn't recognize — is preserved
byte-for-byte on every save, including edits made through the app's UI.
**Filenames never change after creation**; reschedule a task by editing its
`date`/`start`/`end` fields, not by renaming the file.

One caveat: the app's edit sheet loads a snapshot of the file when you
open it and writes that whole snapshot back on Save. If Claude rewrites a
file while its edit sheet happens to be open, hitting Save will overwrite
Claude's change (last write wins) — Cancel is always safe. In practice,
just close any open edit sheet before asking Claude to update the day.

**The body is the description** — rendered as markdown, so `[label](url)`
links (slides, docs, tickets) and bare `https://…` URLs are clickable.
This is where meeting prep notes go.

The app polls `Tasks/` about once a second, so edits from outside the app
(Finder, a text editor, Claude Code) show up automatically — no restart
needed.

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

## Building / running

```sh
./build.sh       # builds ToDo.app (requires Xcode Command Line Tools + Swift)
open "ToDo.app"
```

The app is unsigned (ad-hoc signed locally by `build.sh` so macOS will run
it). Since it's built locally rather than downloaded, it isn't
quarantined, so it should just open normally.

Requires macOS 13+.
