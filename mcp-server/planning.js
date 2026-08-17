// PA-style scheduling reasoning: date ranges, conflict detection, and free-
// slot finding. Deliberately returns structured facts only (counts, hours,
// overlapping ids, candidate windows) — never a baked-in judgment like
// "this day is too busy". That call belongs to the conversation, made fresh
// from real numbers each time, not to a hardcoded threshold in here.
'use strict';

const { dateStringOf, formatMinutesDisplay } = require('./taskfile');

function addDays(dateString, n) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dateString);
  if (!m) return dateString;
  const d = new Date(+m[1], +m[2] - 1, +m[3]);
  d.setDate(d.getDate() + n);
  return dateStringOf(d);
}

function dayOfWeekLabel(dateString) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dateString);
  if (!m) return dateString;
  const d = new Date(+m[1], +m[2] - 1, +m[3]);
  return new Intl.DateTimeFormat('en-US', { weekday: 'long' }).format(d);
}

/** Inclusive list of "yyyy-MM-dd" strings from start through end. */
function datesInRange(startDateString, endDateString) {
  const dates = [];
  let cur = startDateString;
  let guard = 0;
  while (cur <= endDateString && guard < 366) {
    dates.push(cur);
    cur = addDays(cur, 1);
    guard++;
  }
  return dates;
}

/** Resolves the common {date, end_date, days_ahead} tool params into a
 * concrete list of "yyyy-MM-dd" days, defaulting to just today. */
function resolveDateRange({ date, end_date, days_ahead }, today) {
  const start = date && /^\d{4}-\d{2}-\d{2}$/.test(date) ? date : today;
  if (end_date && /^\d{4}-\d{2}-\d{2}$/.test(end_date)) {
    return datesInRange(start, end_date);
  }
  if (typeof days_ahead === 'number' && days_ahead > 0) {
    return datesInRange(start, addDays(start, days_ahead - 1));
  }
  return [start];
}

// How much room an item actually takes up. These two constants, and the
// function below, are the SINGLE definition of that — mirrored from
// Sources/ToDoCore/TimelineLayout.swift.
//
// They used to be inlined separately in each function, and had drifted:
// findConflicts used the item's true length while findOverlappingIds applied
// a 15-minute floor. So add_task would happily book something at 10:10
// against a 10:00–10:05 item, and then week_overview — and the app's own row
// warning — immediately called the same pair overlapping.
const ASSUMED_DURATION_MINUTES = 30;
const MINIMUM_FOOTPRINT_MINUTES = 15;

/** The [start, end) an item occupies, or null if it isn't scheduled. */
function effectiveRange(task) {
  const start = task.startMinutes;
  if (start == null) return null;
  const end = Math.max(
    task.endMinutes ?? start + ASSUMED_DURATION_MINUTES,
    start + MINIMUM_FOOTPRINT_MINUTES
  );
  return { start, end };
}

/** Every not-done, timed item on `dateString` other than `excludeId` whose
 * range overlaps [startMinutes, endMinutes). Mirrors the overlap check the
 * app itself uses, so a conflict flagged here matches what the row-level
 * "Overlaps another item" warning would show. */
function findConflicts(tasks, dateString, startMinutes, endMinutes, excludeId) {
  const from = startMinutes;
  const to = Math.max(endMinutes, startMinutes + MINIMUM_FOOTPRINT_MINUTES);
  return tasks.filter((t) => {
    if (t.id === excludeId) return false;
    if (t.done) return false;
    if (t.dateString !== dateString) return false;
    const range = effectiveRange(t);
    if (!range) return false;
    return from < range.end && range.start < to;
  });
}

/** Same pairwise-overlap sweep as Sources/ToDoApp/TimelineLayout.swift's
 * overlappingTaskIDs — kept in sync deliberately so "overlapping" means the
 * same thing here as it does in the app's UI. */
function findOverlappingIds(items) {
  const entries = items
    .map((t) => {
      const range = effectiveRange(t);
      return range ? { id: t.id, ...range } : null;
    })
    .filter(Boolean)
    .sort((a, b) => a.start - b.start);

  const overlapping = new Set();
  for (let i = 0; i < entries.length; i++) {
    for (let j = i + 1; j < entries.length; j++) {
      if (entries[j].start >= entries[i].end) break;
      overlapping.add(entries[i].id);
      overlapping.add(entries[j].id);
    }
  }
  return overlapping;
}

/** Free windows >= durationMinutes on each of `dates`, within
 * [workStartMinutes, workEndMinutes), keeping bufferMinutes clear on both
 * sides of every existing not-done timed item. On `today`, never offers a
 * slot that's already in the past. */
function findFreeSlots(tasks, { dates, durationMinutes, bufferMinutes, workStartMinutes, workEndMinutes, maxResults, today, nowMinutes }) {
  const results = [];
  for (const dateString of dates) {
    const dayStart = dateString === today ? Math.max(workStartMinutes, nowMinutes ?? workStartMinutes) : workStartMinutes;
    if (dayStart >= workEndMinutes) continue;

    const busy = tasks
      .filter((t) => !t.done && t.dateString === dateString)
      .map(effectiveRange)
      .filter(Boolean)
      .map((range) => ({
        start: Math.max(dayStart, range.start - bufferMinutes),
        end: Math.min(workEndMinutes, range.end + bufferMinutes),
      }))
      // Clamping an item that lies wholly OUTSIDE the working window inverts
      // it (an 8pm meeting against a 7pm work_end becomes start 8pm/end 7pm).
      // An inverted interval is not a real busy block, and left in it makes
      // the sweep below emit a "free slot" running past work_end. Anything
      // that survives the clamp with end <= start contributed nothing to
      // this day's window, so drop it.
      .filter((b) => b.end > b.start)
      .sort((a, b) => a.start - b.start);

    const merged = [];
    for (const b of busy) {
      const last = merged[merged.length - 1];
      if (last && b.start <= last.end) {
        last.end = Math.max(last.end, b.end);
      } else {
        merged.push({ ...b });
      }
    }

    let cursor = dayStart;
    for (const b of merged) {
      if (b.start - cursor >= durationMinutes) {
        results.push({ date: dateString, startMinutes: cursor, endMinutes: b.start });
      }
      cursor = Math.max(cursor, b.end);
    }
    if (workEndMinutes - cursor >= durationMinutes) {
      results.push({ date: dateString, startMinutes: cursor, endMinutes: workEndMinutes });
    }

    if (maxResults && results.length >= maxResults) break;
  }
  return maxResults ? results.slice(0, maxResults) : results;
}

function formatSlot(slot) {
  return `${slot.date} ${formatMinutesDisplay(slot.startMinutes)}–${formatMinutesDisplay(slot.endMinutes)}`;
}

module.exports = {
  ASSUMED_DURATION_MINUTES,
  MINIMUM_FOOTPRINT_MINUTES,
  effectiveRange,
  addDays,
  dayOfWeekLabel,
  datesInRange,
  resolveDateRange,
  findConflicts,
  findOverlappingIds,
  findFreeSlots,
  formatSlot,
};
