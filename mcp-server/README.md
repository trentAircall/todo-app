# To-Do app MCP server

A local MCP server that lets Claude Desktop (including voice mode, if that
surface calls connector tools — see caveat below) act on the same
`Tasks/*.md` files the Swift app reads and writes. It's a second writer on
the same folder, so it follows the same rules as the app: only touch the
frontmatter field being changed, never touch unknown keys/comments/body
unless explicitly asked to, filenames never change after creation, delete
means Trash not permanent removal.

Runs over stdio — Claude Desktop spawns it as a plain local process on
this Mac. Nothing here listens on a network port or is reachable from
anywhere but this machine.

## Tools

| Tool | What it does |
|---|---|
| `list_tasks` | What's on a day or range (`today`, `tomorrow`, `all`, `yyyy-MM-dd`, plus `end_date`/`days_ahead` for a range). `include_notes` returns full notes text, not just title/time/tags. |
| `search_tasks` | Cross-day search by title/tag/notes text. Also takes `include_notes`. |
| `find_free_slots` | Availability-aware slot finding — a duration + a range in, real open windows out, respecting working hours (7am–7pm default) and a buffer (15 min default) around existing items. Never offers a slot already in the past on today. |
| `week_overview` | Per-day facts (count, scheduled hours, overlaps) across a range — structured data only, no baked-in "too busy" judgment. |
| `needs_attention` | Proactive check: upcoming meetings with thin/no prep notes, and follow-up-style tasks that have sat unscheduled a while. |
| `daily_briefing` | One-call "brief me on today": schedule + prep gaps + anything still overdue. |
| `add_task` | Create a task or meeting. Checks for a time conflict first and asks for `confirm: true` rather than silently double-booking. |
| `update_task` | Mark done/not done, reschedule, retitle, retag, change link/notes — only the fields passed are touched. Same conflict-check-then-confirm behavior when the new time overlaps something else. |
| `create_followup` | Same convention as the app's own "Follow-up" button: new task, inherits tags, gets a `**Follow-up from:** <title> — <date>` line in the body. |
| `delete_task` | Moves a file to the macOS Trash (via Finder), not a permanent delete. |
| `find_task_by_source` | Idempotency lookup — given a `source` value (e.g. `gcal:<event_id>`), finds the task already linked to it, if any. The check a sync job should run before creating anything, so a rerun updates the existing file instead of duplicating it. |
| `log_enrichment` | Appends one line to a task's `## Enrichment log` section — what was pulled in, from where, when. Only ever appends; never touches the rest of the file. |

`update_task`, `create_followup`, and `delete_task` all take an
`id_or_query` — either an exact id (shown in `list_tasks`/`search_tasks`
output) or a fuzzy phrase like `"the Judith meeting"`. A fuzzy match that
isn't unique returns a numbered list to disambiguate instead of guessing —
the calling assistant should ask which one and call again with the exact
id, never guess on an ambiguous match.

Deliberate design choice: there's no computed "how good is this task"
score anywhere. `include_notes` exposes the real text so the assistant can
judge documentation quality itself, live, the way a PA reading the actual
file would — not a stored number pretending to quantify something that's
inherently qualitative.

## Provenance: `source` and the enrichment log

`add_task`/`update_task` accept an optional `source` field (e.g.
`gcal:<event_id>`) — a plain frontmatter key, same mechanism as `tags` or
`link`. It's known to this server but **not** to the Swift app's
`knownKeys` — deliberately. The app already preserves any frontmatter key
it doesn't recognize byte-for-byte, so `source:` just rides along as
"unknown data" from its point of view. No Swift changes were needed for
this, which is really the whole `TaskFile.setValue`/preserve-unknown-data
design proving out exactly what it was built for.

`log_enrichment` extends the same never-fabricate principle one step
further: a `## Enrichment log` section at the end of the body records what
grounded a note and when, so a claim is traceable after the fact, not just
trusted because it was true at write time.

Neither of these is wired into an actual automation yet — they're the
groundwork for one (a scheduled sync job that upserts from Calendar/Drive/
Mail/Slack/Piper instead of creating duplicates), not the automation
itself. That's still a separate, explicit decision — it touches live
external systems (recoloring real calendar events, sending Slack
messages) and reverses an earlier deliberate choice to keep calendar
import on-request rather than automatic, so it isn't something to infer
consent for from adjacent work.

## Setup (Claude Desktop)

**Settings → Extensions → Advanced → Install Unpackaged Extension**, then
select this `mcp-server` folder directly. It already has a `manifest.json`
(MCP Bundle / "mcpb" format, `"type": "node"`, `"command": "node"`) so
nothing needs zipping or copying — Claude Desktop runs this folder in
place, and with **"Use Built-in Node.js for MCP" enabled** (Settings →
Extensions → Advanced), it resolves that `"node"` to its own bundled
runtime rather than the system one, so no absolute path is needed here.

If that option isn't available in your build, fall back to editing
`~/Library/Application Support/Claude/claude_desktop_config.json` directly
— merge in an `mcpServers` entry, don't replace the whole file (it already
has other settings in it):

```json
{
  "mcpServers": {
    "todo-app": {
      "command": "/opt/homebrew/bin/node",
      "args": ["/Users/thome/Developer/To-Do App/mcp-server/index.js"]
    }
  }
}
```

(Absolute path to `node` here, unlike the manifest above — this older
`mcpServers` config path isn't covered by the "Use Built-in Node.js"
toggle, and GUI apps on macOS don't always inherit a terminal's PATH, so a
bare `"node"` command can fail to launch silently in this fallback.)

Restart Claude Desktop after installing/editing so it picks up the server.

## Tests

```sh
npm install   # first time only
npm test
```

Two suites, both worth understanding before changing anything here:

- **`test/conformance.test.js`** — the file format. It reads
  `../Tests/fixtures/cases.json`, and so does the Swift suite
  (`swift test` from the project root). This server and the app are
  independent implementations of one format; the fixtures are what stop
  them drifting. **Change parsing or writing behaviour and you must add a
  case to `cases.json` and run both suites.**
- **`test/tools.test.js`** — the tools themselves, end to end: it spawns a
  real server process, talks real JSON-RPC over stdio, and points it at a
  throwaway folder via `TODO_APP_TASKS_DIR`. This is the only coverage of
  what happens between "Claude called a tool" and "a file changed."

To poke at it by hand instead, `node index.js` talks MCP over stdio, so it
won't print anything interesting on its own — drive it with any MCP client,
or copy the harness at the top of `test/tools.test.js`.

## Debugging

If something misbehaves, check `server.log` in this folder first —
Claude Desktop's own MCP logs (`~/Library/Logs/Claude/mcp-server-todo-app-mcp.log`)
only record protocol messages (request/response), not this server's own
console output, so they won't show a stack trace if something throws.
`server.log` logs every tool call, its arguments, and any error with a
full stack trace. Every tool handler is wrapped so a thrown error returns
a normal (if unhelpful) response instead of crashing the process —
before that fix, one bad call could silently kill the server mid-session
and Claude Desktop wouldn't reliably reconnect within that same
conversation turn.

## Voice mode

Confirmed working — voice mode does call this connector's tools, the same
as text chat. (An earlier live guess from the assistant claiming voice and
text have different tool access was wrong and has been retracted; don't
trust that explanation if it comes up again.) What's actually been seen to
go wrong is occasional mid-session flakiness — the connector process
dying or losing its registration for a few turns, unrelated to voice vs.
text. If that happens, restarting Claude Desktop reliably clears it.
