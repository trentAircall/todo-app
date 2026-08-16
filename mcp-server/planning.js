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

/** Every not-done, timed item on `dateString` other than `excludeId` whose
 * range overlaps [startMinutes, endMinutes). Mirrors the overlap check the
 * app itself uses, so a conflict flagged here matches what the row-level
 * "Overlaps another item" warning would show. */
function findConflicts(tasks, dateString, startMinutes, endMinutes, excludeId) {
  return tasks.filter((t) => {
    if (t.id === excludeId) return false;
    if (t.done) return false;
    if (t.dateString !== dateString) return false;
    if (t.startMinutes == null) return false;
    const tStart = t.startMinutes;
    const tEnd = t.endMinutes ?? tStart + 30;
    return startMinutes < tEnd && tStart < endMinutes;
  });
}

/** Same pairwise-overlap sweep as Sources/ToDoApp/TimelineLayout.swift's
 * overlappingTaskIDs — kept in sync deliberately so "overlapping" means the
 * same thing here as it does in the app's UI. */
function findOverlappingIds(items) {
  const entries = items
    .filter((t) => t.startMinutes != null)
    .map((t) => ({
      id: t.id,
      start: t.startMinutes,
      end: Math.max(t.endMinutes ?? t.startMinutes + 30, t.startMinutes + 15),
    }))
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
      .filter((t) => !t.done && t.dateString === dateString && t.startMinutes != null)
      .map((t) => ({
        start: Math.max(dayStart, t.startMinutes - bufferMinutes),
        end: Math.min(workEndMinutes, (t.endMinutes ?? t.startMinutes + 30) + bufferMinutes),
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
  addDays,
  dayOfWeekLabel,
  datesInRange,
  resolveDateRange,
  findConflicts,
  findOverlappingIds,
  findFreeSlots,
  formatSlot,
};
