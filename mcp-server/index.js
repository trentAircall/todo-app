#!/usr/bin/env node
// Local MCP server for the To-Do app's Tasks/ folder — lets Claude (in
// Claude Desktop, including voice mode, if that surface calls connector
// tools) add, complete, reschedule, search, and chain follow-up tasks live
// in conversation, reading/writing the exact same .md files the Swift app
// uses. Runs over stdio; Claude Desktop spawns it as a local process, so
// nothing here is reachable off this Mac.
'use strict';

const path = require('path');
const fs = require('fs');
const { z } = require('zod');
const { McpServer } = require('@modelcontextprotocol/sdk/server/mcp.js');
const { StdioServerTransport } = require('@modelcontextprotocol/sdk/server/stdio.js');

const {
  todayString,
  isDateString,
  DATE_RE,
  shortDateLabel,
  parseTimeToMinutes,
  formatMinutesDisplay,
  formatMinutesHHmm,
  newFilename,
  loadAllTasks,
  setValue,
  serializeWithEdits,
  newFileContents,
  appendEnrichmentEntry,
  uniqueFilePath,
  writeAtomically,
  trashFile,
  StaleWriteError,
} = require('./taskfile');
const { resolveTask, formatTaskLine, formatCandidates } = require('./resolve');
const {
  addDays,
  dayOfWeekLabel,
  resolveDateRange,
  findConflicts,
  findOverlappingIds,
  findFreeSlots,
  formatSlot,
} = require('./planning');

function nowMinutes() {
  const d = new Date();
  return d.getHours() * 60 + d.getMinutes();
}

// NOT __dirname-relative: Claude Desktop's "Install Unpackaged Extension"
// copies this folder into its own managed extensions directory rather than
// running it in place, so a relative path silently resolves to a decoy
// sibling folder there instead of the app's real Tasks/. This must stay a
// real absolute path to the one true Tasks folder regardless of where this
// server itself ends up running from. Override with TODO_APP_TASKS_DIR if
// this project ever moves.
const TASKS_DIR = process.env.TODO_APP_TASKS_DIR || '/Users/thome/Developer/To-Do App/Tasks';
try {
  fs.mkdirSync(TASKS_DIR, { recursive: true });
} catch (err) {
  console.error(`[todo-mcp] could not create Tasks dir: ${err.message}`);
}

function text(s) {
  return { content: [{ type: 'text', text: s }] };
}

function loadTasks() {
  return loadAllTasks(TASKS_DIR);
}

/**
 * A bad `date` must never reach the file. Both parsers reject anything that
 * isn't "yyyy-MM-dd" and silently fall back to the file's creation day, so
 * writing e.g. `date: tomorrow` doesn't fail loudly — it teleports the task
 * to a day nobody chose. Resolving relative words here, and refusing
 * anything still unrecognized, keeps that class of bug out entirely.
 *
 * Returns { date } on success or { error } with a message to hand back.
 */
function resolveDateArg(value, today, { fallback = today } = {}) {
  if (value === undefined || value === null || value === '') return { date: fallback };
  const raw = String(value).trim();
  const lower = raw.toLowerCase();
  if (lower === 'today') return { date: today };
  if (lower === 'tomorrow') return { date: addDays(today, 1) };
  if (lower === 'yesterday') return { date: addDays(today, -1) };
  // isDateString checks the shape AND that the day actually exists, so a
  // well-formed-but-impossible 2026-02-31 is rejected here rather than
  // round-tripping into March and quietly moving the task.
  if (isDateString(raw)) return { date: raw };
  if (DATE_RE.test(raw)) return { error: `"${raw}" isn't a real date.` };
  return {
    error: `Couldn't understand the date "${raw}". Use "yyyy-MM-dd", or "today"/"tomorrow".`,
  };
}

/** Turns the optimistic-concurrency failure into an instruction Claude can
 * actually act on, rather than an opaque internal error. */
function staleWriteMessage(task) {
  return (
    `"${task.title}" was changed by something else (the app, or an editor) after I read it, ` +
    `so I stopped rather than overwrite that change. Re-read the task and try again.`
  );
}

// Claude Desktop's own MCP log only records protocol messages (request/
// response), not this process's console output — so a crash here leaves no
// trace anywhere reachable. Keep our own, and never let a thrown error take
// the whole server down mid-conversation: every tool call goes through this
// wrapper, which turns an exception into a normal (isError) tool result
// instead of an uncaught exception.
const LOG_FILE = path.join(__dirname, 'server.log');
const LOG_MAX_BYTES = 256 * 1024;

// This log records real task titles and notes, so it is not something to
// let grow forever in a directory nobody looks at. One rotation, capped —
// enough to debug the last session, not an unbounded shadow copy of the
// user's calendar.
function rotateLogIfNeeded() {
  try {
    if (fs.statSync(LOG_FILE).size > LOG_MAX_BYTES) {
      fs.renameSync(LOG_FILE, `${LOG_FILE}.1`);
    }
  } catch {
    // no log file yet, or rotation failed — either way, keep going
  }
}

function log(msg) {
  const line = `${new Date().toISOString()} ${msg}\n`;
  try {
    rotateLogIfNeeded();
    fs.appendFileSync(LOG_FILE, line);
  } catch {
    // best-effort — never let logging itself be a new failure mode
  }
  console.error(`[todo-mcp] ${msg}`);
}

/** Arguments can carry a whole meeting's notes; log enough to debug a call
 * without transcribing the task body into the log file. */
function summarizeArgs(args) {
  let json;
  try {
    json = JSON.stringify(args);
  } catch {
    return '[unserializable args]';
  }
  if (json == null) return '{}';
  return json.length > 300 ? `${json.slice(0, 300)}…(${json.length} chars)` : json;
}

function safeHandler(name, fn) {
  return async (args) => {
    log(`call ${name} ${summarizeArgs(args)}`);
    try {
      const result = await fn(args);
      log(`ok ${name}`);
      return result;
    } catch (err) {
      log(`ERROR in ${name}: ${err && err.stack ? err.stack : err}`);
      return {
        content: [{ type: 'text', text: `The ${name} tool hit an internal error: ${err.message || err}` }],
        isError: true,
      };
    }
  };
}

process.on('uncaughtException', (err) => {
  log(`UNCAUGHT EXCEPTION (server stays up): ${err && err.stack ? err.stack : err}`);
});
process.on('unhandledRejection', (reason) => {
  log(`UNHANDLED REJECTION (server stays up): ${reason && reason.stack ? reason.stack : reason}`);
});

const server = new McpServer({ name: 'todo-app', version: '1.0.0' });

server.registerTool(
  'list_tasks',
  {
    title: 'List tasks',
    description:
      "Lists tasks/meetings from the user's local run-sheet to-do app for a day or a range of days. " +
      'Use this to answer "what\'s on today", "what do I have tomorrow", "what\'s on this week" (via days_ahead), etc.',
    inputSchema: {
      date: z
        .string()
        .optional()
        .describe('"today" (default), "tomorrow", "all", or an exact "yyyy-MM-dd" start date.'),
      end_date: z.string().optional().describe('"yyyy-MM-dd" — makes this a range from `date` through `end_date`, inclusive.'),
      days_ahead: z
        .number()
        .int()
        .positive()
        .optional()
        .describe('Alternative to end_date: how many days from `date` to include, e.g. 7 for "this week".'),
      include_done: z
        .boolean()
        .optional()
        .describe('Include already-completed items too. Default false (only what\'s left to do).'),
      include_notes: z
        .boolean()
        .optional()
        .describe("Include each task's full notes/description text — needed to judge how well-documented something is."),
    },
  },
  safeHandler('list_tasks', async ({ date, end_date, days_ahead, include_done, include_notes }) => {
    const tasks = loadTasks();
    const today = todayString();

    let dates = null;
    if (String(date).toLowerCase() !== 'all') {
      const start = resolveDateArg(date, today);
      if (start.error) return text(start.error);
      let resolvedEnd;
      if (end_date !== undefined) {
        const parsedEnd = resolveDateArg(end_date, today);
        if (parsedEnd.error) return text(parsedEnd.error);
        resolvedEnd = parsedEnd.date;
      }
      dates = resolveDateRange({ date: start.date, end_date: resolvedEnd, days_ahead }, today);
    }
    const dateSet = dates ? new Set(dates) : null;

    let filtered = dateSet ? tasks.filter((t) => dateSet.has(t.dateString)) : tasks.slice();
    if (!include_done) filtered = filtered.filter((t) => !t.done);
    filtered.sort((a, b) => {
      if (a.dateString !== b.dateString) return a.dateString < b.dateString ? -1 : 1;
      return (a.startMinutes ?? 9999) - (b.startMinutes ?? 9999);
    });

    if (!filtered.length) {
      if (!dates) return text('No tasks found.');
      const range = dates.length > 1 ? `from ${dates[0]} to ${dates[dates.length - 1]}` : `on ${dates[0]}`;
      return text(`Nothing scheduled ${range}.`);
    }
    const showDate = !dates || dates.length > 1;
    const lines = filtered.map((t) => formatTaskLine(t, { showDate, includeNotes: include_notes }));
    return text(lines.join('\n'));
  })
);

server.registerTool(
  'search_tasks',
  {
    title: 'Search tasks',
    description:
      'Searches every task/meeting across all days (not just today) by title, tag, or notes text. ' +
      'Use this when the user refers to something without saying which day it\'s on.',
    inputSchema: {
      query: z.string().describe('Text to search for, e.g. a company name, project, or title fragment.'),
      include_notes: z.boolean().optional().describe("Include each match's full notes/description text."),
    },
  },
  safeHandler('search_tasks', async ({ query, include_notes }) => {
    const q = query.trim().toLowerCase();
    if (!q) return text('Give me something to search for.');
    const tasks = loadTasks().filter(
      (t) =>
        t.title.toLowerCase().includes(q) ||
        t.tags.some((tag) => tag.toLowerCase().includes(q)) ||
        t.body.toLowerCase().includes(q)
    );
    if (!tasks.length) return text(`No matches for "${query}".`);
    tasks.sort((a, b) => {
      if (a.dateString !== b.dateString) return a.dateString < b.dateString ? -1 : 1;
      return (a.startMinutes ?? 9999) - (b.startMinutes ?? 9999);
    });
    return text(tasks.map((t) => formatTaskLine(t, { showDate: true, includeNotes: include_notes })).join('\n'));
  })
);

server.registerTool(
  'find_free_slots',
  {
    title: 'Find free time slots',
    description:
      'Finds real open windows in the schedule for booking something new — the "find me 30 minutes tomorrow" ' +
      'request. Respects working hours (7am–7pm by default) and keeps a buffer around existing meetings so a ' +
      "suggestion never butts right up against something else.",
    inputSchema: {
      duration_minutes: z.number().int().positive().describe('How long a slot is needed, in minutes.'),
      date: z.string().optional().describe('"today" (default), "tomorrow", or "yyyy-MM-dd" — start of the search range.'),
      end_date: z.string().optional().describe('"yyyy-MM-dd" to search a range through this date.'),
      days_ahead: z.number().int().positive().optional().describe('Alternative to end_date, e.g. 7 for "this week".'),
      buffer_minutes: z.number().int().nonnegative().optional().describe('Minimum gap to keep around existing items. Default 15.'),
      work_start: z.string().optional().describe('Earliest bookable time, e.g. "7:00 am". Default 7:00 am.'),
      work_end: z.string().optional().describe('Latest bookable time, e.g. "7:00 pm". Default 7:00 pm.'),
      max_results: z.number().int().positive().optional().describe('Cap on how many candidate slots to return. Default 5.'),
    },
  },
  safeHandler(
    'find_free_slots',
    async ({ duration_minutes, date, end_date, days_ahead, buffer_minutes, work_start, work_end, max_results }) => {
      const today = todayString();
      const start = resolveDateArg(date, today);
      if (start.error) return text(start.error);
      let resolvedEnd;
      if (end_date !== undefined) {
        const parsedEnd = resolveDateArg(end_date, today);
        if (parsedEnd.error) return text(parsedEnd.error);
        resolvedEnd = parsedEnd.date;
      }
      const dates = resolveDateRange({ date: start.date, end_date: resolvedEnd, days_ahead }, today);

      const workStartMinutes = work_start ? parseTimeToMinutes(work_start) : 7 * 60;
      const workEndMinutes = work_end ? parseTimeToMinutes(work_end) : 19 * 60;
      if (workStartMinutes == null || workEndMinutes == null || workStartMinutes >= workEndMinutes) {
        return text("Couldn't understand the working-hours window given.");
      }

      const slots = findFreeSlots(loadTasks(), {
        dates,
        durationMinutes: duration_minutes,
        bufferMinutes: buffer_minutes ?? 15,
        workStartMinutes,
        workEndMinutes,
        maxResults: max_results ?? 5,
        today,
        nowMinutes: nowMinutes(),
      });

      if (!slots.length) return text(`No ${duration_minutes}-minute slot found in that window.`);
      return text(slots.map(formatSlot).join('\n'));
    }
  )
);

server.registerTool(
  'week_overview',
  {
    title: 'Week overview',
    description:
      'The shape of several days at a glance — meeting count, scheduled hours, and overlaps per day. Returns ' +
      'structured facts only, deliberately no "this day is too busy" judgment baked in — that call belongs in the ' +
      'conversation, made fresh from real numbers, not a hardcoded threshold.',
    inputSchema: {
      date: z.string().optional().describe('"today" (default) or "yyyy-MM-dd" — start of the range.'),
      days_ahead: z.number().int().positive().optional().describe('How many days to cover, starting from `date`. Default 7.'),
    },
  },
  safeHandler('week_overview', async ({ date, days_ahead }) => {
    const today = todayString();
    const start = resolveDateArg(date, today);
    if (start.error) return text(start.error);
    const dates = resolveDateRange({ date: start.date, days_ahead: days_ahead ?? 7 }, today);
    const tasks = loadTasks();

    const lines = dates.map((dateString) => {
      const dayTasks = tasks.filter((t) => t.dateString === dateString && !t.done);
      const timed = dayTasks.filter((t) => t.startMinutes != null);
      // A hand-edited file can carry an end before its start; clamping at 0
      // keeps one bad row from making the whole day's booked hours nonsense.
      const totalMinutes = timed.reduce(
        (sum, t) => sum + Math.max(0, (t.endMinutes ?? t.startMinutes + 30) - t.startMinutes),
        0
      );
      const overlapCount = findOverlappingIds(timed).size;
      const overlapNote = overlapCount ? `, ${overlapCount} overlapping` : '';
      return (
        `${dateString} (${dayOfWeekLabel(dateString)}): ${timed.length} scheduled, ` +
        `${dayTasks.length - timed.length} unscheduled, ${(totalMinutes / 60).toFixed(1)}h booked${overlapNote}`
      );
    });
    return text(lines.join('\n'));
  })
);

server.registerTool(
  'needs_attention',
  {
    title: 'What needs attention',
    description:
      'The proactive "before you even ask" check — upcoming meetings with no real prep notes yet, and ' +
      'follow-up-style tasks that have sat unscheduled for a while. Meant to be called unprompted sometimes, the ' +
      'way a good PA flags things before they become urgent rather than waiting to be asked.',
    inputSchema: {
      lookahead_days: z.number().int().positive().optional().describe('How many days ahead to check meetings for missing notes. Default 2.'),
      stale_days: z.number().int().positive().optional().describe('How many days unscheduled before a task counts as "stale". Default 5.'),
    },
  },
  safeHandler('needs_attention', async ({ lookahead_days, stale_days }) => {
    const today = todayString();
    const horizon = addDays(today, lookahead_days ?? 2);
    const staleCutoffMs = Date.now() - (stale_days ?? 5) * 24 * 60 * 60 * 1000;

    const tasks = loadTasks();

    const thinPrep = tasks.filter(
      (t) =>
        !t.done &&
        t.kind === 'meeting' &&
        t.startMinutes != null &&
        t.dateString >= today &&
        t.dateString <= horizon &&
        t.body.trim().length < 20
    );

    // "Stale" means it was created a while ago AND its day has arrived or
    // passed. A task deliberately parked on a future date isn't neglected,
    // it's scheduled — flagging those trains the user to ignore this tool.
    const staleFollowUps = tasks.filter(
      (t) =>
        !t.done &&
        t.startMinutes == null &&
        t.dateString <= today &&
        new Date(t.createdAt).getTime() < staleCutoffMs
    );

    if (!thinPrep.length && !staleFollowUps.length) {
      return text("Nothing needs attention — upcoming meetings have notes, no stale unscheduled items.");
    }

    const parts = [];
    if (thinPrep.length) {
      parts.push(
        'Meetings coming up with little or no prep notes:\n' +
          thinPrep.map((t) => formatTaskLine(t, { showDate: true })).join('\n')
      );
    }
    if (staleFollowUps.length) {
      parts.push(
        'Unscheduled tasks sitting a while:\n' +
          staleFollowUps.map((t) => formatTaskLine(t, { showDate: true })).join('\n')
      );
    }
    return text(parts.join('\n\n'));
  })
);

server.registerTool(
  'daily_briefing',
  {
    title: 'Daily briefing',
    description:
      'One call for "brief me on today" — the day\'s schedule plus anything that needs attention, the way a PA ' +
      "starts the morning by reviewing the calendar before the day begins.",
    inputSchema: {
      date: z.string().optional().describe('"today" (default), "tomorrow", or "yyyy-MM-dd".'),
    },
  },
  safeHandler('daily_briefing', async ({ date }) => {
    const today = todayString();
    const parsed = resolveDateArg(date, today);
    if (parsed.error) return text(parsed.error);
    const resolvedDate = parsed.date;

    const tasks = loadTasks();
    const dayTasks = tasks.filter((t) => t.dateString === resolvedDate && !t.done);
    dayTasks.sort((a, b) => (a.startMinutes ?? 9999) - (b.startMinutes ?? 9999));
    const scheduleText = dayTasks.length ? dayTasks.map((t) => formatTaskLine(t)).join('\n') : 'Nothing scheduled.';

    const thinPrep = dayTasks.filter(
      (t) => t.kind === 'meeting' && t.startMinutes != null && t.body.trim().length < 20
    );
    const overdue = resolvedDate === today ? tasks.filter((t) => !t.done && t.dateString < today) : [];

    const parts = [`Schedule for ${resolvedDate}:\n${scheduleText}`];
    if (thinPrep.length) {
      parts.push(`No prep notes yet:\n${thinPrep.map((t) => formatTaskLine(t)).join('\n')}`);
    }
    if (overdue.length) {
      parts.push(`Still overdue from earlier:\n${overdue.map((t) => formatTaskLine(t, { showDate: true })).join('\n')}`);
    }
    return text(parts.join('\n\n'));
  })
);

server.registerTool(
  'add_task',
  {
    title: 'Add a task or meeting',
    description:
      "Creates a new task or meeting in the user's run-sheet to-do app. " +
      'Use this whenever the user asks to add/create/schedule something.',
    inputSchema: {
      title: z.string().describe('Short title for the task or meeting.'),
      kind: z.enum(['task', 'meeting']).optional().describe('Default "task".'),
      date: z.string().optional().describe('"yyyy-MM-dd". Default: today.'),
      start: z.string().optional().describe('Start time, e.g. "3:00 pm" or "15:00". Omit for an unscheduled task.'),
      end: z.string().optional().describe('End time, same format as start. Optional even if start is set.'),
      tags: z.array(z.string()).optional().describe('Short tags for sorting, e.g. company name or "focus".'),
      link: z.string().optional().describe('A URL — Zoom/Meet link, doc, etc.'),
      notes: z.string().optional().describe('Free-text notes/description. Markdown links are clickable in the app.'),
      source: z
        .string()
        .optional()
        .describe(
          'Provenance reference, e.g. "gcal:<event_id>" — lets find_task_by_source find this task again later ' +
            'instead of a sync job creating a duplicate. Invisible in the app UI; purely a backend lookup key.'
        ),
      confirm: z
        .boolean()
        .optional()
        .describe('Set true to book anyway even if it conflicts with something else already on the calendar.'),
    },
  },
  safeHandler('add_task', async ({ title, kind, date, start, end, tags, link, notes, source, confirm }) => {
    const trimmedTitle = (title || '').trim();
    if (!trimmedTitle) return text('I need a title to add a task.');

    let startMinutes = null;
    if (start) {
      startMinutes = parseTimeToMinutes(start);
      if (startMinutes == null) return text(`Couldn't understand the start time "${start}". Try e.g. "3:00 pm" or "15:00".`);
    }
    let endMinutes = null;
    if (end) {
      endMinutes = parseTimeToMinutes(end);
      if (endMinutes == null) return text(`Couldn't understand the end time "${end}". Try e.g. "3:30 pm" or "15:30".`);
    }

    const resolvedDate = resolveDateArg(date, todayString());
    if (resolvedDate.error) return text(resolvedDate.error);
    const dateString = resolvedDate.date;

    // A top PA checks against the existing calendar before booking rather
    // than defaulting to yes — surface the clash and let the conversation
    // decide, instead of silently creating an overlap only the app's UI
    // would flag later.
    if (startMinutes != null && !confirm) {
      const conflicts = findConflicts(loadTasks(), dateString, startMinutes, endMinutes ?? startMinutes + 30, null);
      if (conflicts.length) {
        return text(
          `That overlaps ${conflicts.length === 1 ? 'something' : `${conflicts.length} things`} already on ${dateString}:\n` +
            conflicts.map((t) => formatTaskLine(t)).join('\n') +
            `\nCall again with confirm: true to book it anyway.`
        );
      }
    }

    const createdAt = new Date();
    const filename = newFilename(trimmedTitle, createdAt);
    const filePath = uniqueFilePath(TASKS_DIR, filename);
    const contents = newFileContents({
      title: trimmedTitle,
      kind: kind === 'meeting' ? 'meeting' : 'task',
      dateString,
      startMinutes,
      endMinutes,
      tags: (tags || []).map((s) => s.trim()).filter(Boolean),
      link: link || '',
      source: source || '',
      body: notes || '',
      createdAt,
    });
    // Atomic even on create: the app's poller can otherwise catch a
    // partially-written new file and parse it as a malformed task.
    writeAtomically(filePath, contents);

    const when = startMinutes != null ? ` at ${formatMinutesDisplay(startMinutes)}` : '';
    return text(`Added "${trimmedTitle}" on ${dateString}${when}.`);
  })
);

server.registerTool(
  'update_task',
  {
    title: 'Update a task or meeting',
    description:
      'Edits an existing task/meeting — mark done/not done, reschedule, retitle, retag, change its link, or replace ' +
      'its notes. Only the fields you pass are changed; everything else in the file is left exactly as it was. ' +
      'If id_or_query matches more than one task, this returns a list to disambiguate instead of guessing — ask the ' +
      'user which one, then call again with the exact id.',
    inputSchema: {
      id_or_query: z.string().describe('The task\'s id (from a previous list/search) or a fuzzy phrase like "the Judith meeting".'),
      done: z.boolean().optional().describe('Mark complete (true) or not complete (false).'),
      title: z.string().optional(),
      kind: z.enum(['task', 'meeting']).optional(),
      date: z.string().optional().describe('"yyyy-MM-dd" — reschedule to a different day.'),
      start: z.string().optional().describe('New start time, e.g. "3:00 pm" or "15:00".'),
      end: z.string().optional().describe('New end time.'),
      clear_start: z.boolean().optional().describe('Unschedule it (removes both start and end).'),
      clear_end: z.boolean().optional().describe('Remove just the end time, keeping the start.'),
      tags: z.array(z.string()).optional().describe('Replaces the full tag list. Pass an empty array to clear tags.'),
      link: z.string().optional().describe('Replaces the link. Pass an empty string to remove it.'),
      notes: z.string().optional().describe('Replaces the notes/description body entirely.'),
      source: z
        .string()
        .optional()
        .describe('Sets/replaces the provenance reference, e.g. "gcal:<event_id>". Pass an empty string to remove it.'),
      confirm: z
        .boolean()
        .optional()
        .describe('Set true to proceed anyway even if the new time conflicts with something else.'),
    },
  },
  safeHandler('update_task', async ({ id_or_query, done, title, kind, date, start, end, clear_start, clear_end, tags, link, notes, source, confirm }) => {
    const tasks = loadTasks();
    const resolved = resolveTask(tasks, id_or_query);
    if (resolved.status === 'not_found') return text(`No task found matching "${id_or_query}".`);
    if (resolved.status === 'ambiguous') return text(formatCandidates(resolved.candidates, id_or_query));
    const task = resolved.task;

    // Validate the date BEFORE anything else touches the file. Unlike
    // add_task, this path used to write `date` through unchecked.
    let dateString;
    if (date !== undefined) {
      const resolvedDate = resolveDateArg(date, todayString(), { fallback: task.dateString });
      if (resolvedDate.error) return text(resolvedDate.error);
      dateString = resolvedDate.date;
    }

    let startMinutes;
    if (clear_start) startMinutes = null;
    else if (start !== undefined) {
      startMinutes = parseTimeToMinutes(start);
      if (startMinutes == null) return text(`Couldn't understand the start time "${start}".`);
    }
    let endMinutes;
    if (clear_start || clear_end) endMinutes = null;
    else if (end !== undefined) {
      endMinutes = parseTimeToMinutes(end);
      if (endMinutes == null) return text(`Couldn't understand the end time "${end}".`);
    }

    const touchesTiming = date !== undefined || start !== undefined || end !== undefined || clear_start || clear_end;
    if (touchesTiming && !confirm) {
      const effectiveDate = dateString !== undefined ? dateString : task.dateString;
      const effectiveStart = startMinutes !== undefined ? startMinutes : task.startMinutes;
      if (effectiveStart != null) {
        const effectiveEnd = endMinutes !== undefined ? endMinutes : task.endMinutes ?? effectiveStart + 30;
        const conflicts = findConflicts(tasks, effectiveDate, effectiveStart, effectiveEnd, task.id);
        if (conflicts.length) {
          return text(
            `That would overlap ${conflicts.length === 1 ? 'something' : `${conflicts.length} things`} on ${effectiveDate}:\n` +
              conflicts.map((t) => formatTaskLine(t)).join('\n') +
              `\nCall again with confirm: true to proceed anyway.`
          );
        }
      }
    }

    const contents = serializeWithEdits(
      task,
      (lines) => {
        let l = lines;
        if (title !== undefined) l = setValue(l, 'title', title);
        if (kind !== undefined) l = setValue(l, 'kind', kind === 'meeting' ? 'meeting' : null);
        if (done !== undefined) l = setValue(l, 'done', String(!!done));
        if (dateString !== undefined) l = setValue(l, 'date', dateString);
        if (startMinutes !== undefined) {
          l = setValue(l, 'start', startMinutes == null ? null : formatMinutesHHmm(startMinutes));
        }
        if (endMinutes !== undefined) {
          l = setValue(l, 'end', endMinutes == null ? null : formatMinutesHHmm(endMinutes));
        }
        if (tags !== undefined) l = setValue(l, 'tags', tags.length ? tags.join(', ') : null);
        if (link !== undefined) l = setValue(l, 'link', link.trim() ? link.trim() : null);
        if (source !== undefined) l = setValue(l, 'source', source.trim() ? source.trim() : null);
        return l;
      },
      notes !== undefined ? notes : undefined
    );

    try {
      writeAtomically(task.filePath, contents, task.modifiedAtMs);
    } catch (err) {
      if (err instanceof StaleWriteError) return text(staleWriteMessage(task));
      throw err;
    }
    return text(`Updated "${title ?? task.title}" (${dateString ?? task.dateString}).`);
  })
);

server.registerTool(
  'create_followup',
  {
    title: 'Create a follow-up task',
    description:
      'Creates a new task that follows on from an existing task/meeting — e.g. after a meeting wraps up. The new ' +
      'task inherits the source\'s tags and gets a "Follow-up from: <source> — <date>" note in its body so the ' +
      'connection is visible later, matching the app\'s own "Follow-up" button. If id_or_query is ambiguous, this ' +
      'returns candidates instead of guessing.',
    inputSchema: {
      id_or_query: z.string().describe('The source task\'s id or a fuzzy phrase identifying it.'),
      title: z.string().optional().describe('Default: "Follow up: <source title>".'),
      date: z.string().optional().describe('"yyyy-MM-dd" for the new task. Default: today.'),
      tags: z.array(z.string()).optional().describe('Default: inherited from the source task.'),
      notes: z.string().optional().describe('Extra notes appended under the provenance line.'),
    },
  },
  safeHandler('create_followup', async ({ id_or_query, title, date, tags, notes }) => {
    const tasks = loadTasks();
    const resolved = resolveTask(tasks, id_or_query);
    if (resolved.status === 'not_found') return text(`No task found matching "${id_or_query}" to follow up on.`);
    if (resolved.status === 'ambiguous') return text(formatCandidates(resolved.candidates, id_or_query));
    const source = resolved.task;

    const resolvedDate = resolveDateArg(date, todayString());
    if (resolvedDate.error) return text(resolvedDate.error);
    const dateString = resolvedDate.date;
    const finalTitle = (title && title.trim()) || `Follow up: ${source.title}`;
    const tagList = tags !== undefined ? tags.map((s) => s.trim()).filter(Boolean) : source.tags;
    const provenance = `**Follow-up from:** ${source.title} — ${shortDateLabel(source.dateString)}`;
    const body = notes ? `${provenance}\n\n${notes}` : `${provenance}\n\n`;

    const createdAt = new Date();
    const filename = newFilename(finalTitle, createdAt);
    const filePath = uniqueFilePath(TASKS_DIR, filename);
    const contents = newFileContents({
      title: finalTitle,
      kind: 'task',
      dateString,
      startMinutes: null,
      endMinutes: null,
      tags: tagList,
      link: '',
      body,
      createdAt,
    });
    writeAtomically(filePath, contents);

    return text(`Created follow-up "${finalTitle}" on ${dateString}, linked back to "${source.title}".`);
  })
);

server.registerTool(
  'delete_task',
  {
    title: 'Delete a task or meeting',
    description:
      'Moves a task/meeting to the macOS Trash (recoverable, not a permanent delete). If id_or_query is ambiguous, ' +
      'this returns candidates instead of guessing which one to delete.',
    inputSchema: {
      id_or_query: z.string().describe('The task\'s id or a fuzzy phrase identifying it.'),
    },
  },
  safeHandler('delete_task', async ({ id_or_query }) => {
    const tasks = loadTasks();
    const resolved = resolveTask(tasks, id_or_query);
    if (resolved.status === 'not_found') return text(`No task found matching "${id_or_query}".`);
    if (resolved.status === 'ambiguous') return text(formatCandidates(resolved.candidates, id_or_query));
    const task = resolved.task;
    try {
      await trashFile(task.filePath);
    } catch (err) {
      return text(`Couldn't move "${task.title}" to the Trash: ${err.message}`);
    }
    return text(`Moved "${task.title}" to the Trash.`);
  })
);

server.registerTool(
  'find_task_by_source',
  {
    title: 'Find a task by its source reference',
    description:
      'Looks up whether a task already exists for a given source id (e.g. a Calendar event id, "gcal:<id>") — the ' +
      'idempotency check a sync job should run before creating a new task, so a recurring import updates the ' +
      'existing file instead of creating a duplicate.',
    inputSchema: {
      source: z.string().describe('The source identifier to look up, e.g. "gcal:abc123".'),
    },
  },
  safeHandler('find_task_by_source', async ({ source }) => {
    const match = loadTasks().find((t) => t.source === source);
    if (!match) return text(`No task found with source "${source}".`);
    return text(formatTaskLine(match, { showDate: true }));
  })
);

server.registerTool(
  'log_enrichment',
  {
    title: 'Log an enrichment entry',
    description:
      "Appends one line to a task's \"Enrichment log\" section, recording what was pulled in from where and when — " +
      'e.g. "attendee data from Calendar event X" or "linked doc found via Drive search: <title>". Extends the ' +
      "app's never-fabricate principle into a running, readable record: every note stays traceable back to " +
      'something real, not just true at write time. Only ever appends — never touches anything else in the file.',
    inputSchema: {
      id_or_query: z.string().describe('The task\'s id or a fuzzy phrase identifying it.'),
      entry: z.string().describe('One factual line describing what was found/used, e.g. "Drive doc linked: <title> (<url>)".'),
    },
  },
  safeHandler('log_enrichment', async ({ id_or_query, entry }) => {
    const tasks = loadTasks();
    const resolved = resolveTask(tasks, id_or_query);
    if (resolved.status === 'not_found') return text(`No task found matching "${id_or_query}".`);
    if (resolved.status === 'ambiguous') return text(formatCandidates(resolved.candidates, id_or_query));
    const task = resolved.task;

    const newBody = appendEnrichmentEntry(task.body, entry);
    const contents = serializeWithEdits(task, (lines) => lines, newBody);
    try {
      // Especially important here: this tool promises to only ever append.
      // Without the check, a concurrent edit would make it silently replace.
      writeAtomically(task.filePath, contents, task.modifiedAtMs);
    } catch (err) {
      if (err instanceof StaleWriteError) return text(staleWriteMessage(task));
      throw err;
    }
    return text(`Logged to "${task.title}": ${entry}`);
  })
);

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  log(`ready — watching ${TASKS_DIR}`);
}

main().catch((err) => {
  log(`FATAL at startup: ${err && err.stack ? err.stack : err}`);
  process.exit(1);
});
