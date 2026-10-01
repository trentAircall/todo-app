// Mirrors Sources/ToDoCore/TaskItem.swift's TaskFile enum — same "only touch
// the field you're changing" mutation discipline, same filename scheme, and
// the same time grammar. Two writers (the Swift app and this server) share
// one folder, so staying byte-for-byte compatible with the app's own
// parser/serializer is what keeps that safe.
//
// That compatibility is not assumed — it is TESTED. Tests/fixtures/cases.json
// is the shared source of truth for both languages; mcp-server/test/
// conformance.test.js and Tests/ToDoCoreTests/ParserConformanceTests.swift
// both assert against it. If you change parsing behaviour here, change it
// there too and both suites will tell you if the two sides drift.
//
// One deliberate asymmetry: `source` below is known here but NOT in the
// Swift app's knownKeys. That's fine by design — the app already preserves
// any frontmatter key it doesn't recognize byte-for-byte, so a `source:`
// line written here just rides along as "unknown data" from the app's
// point of view, with zero Swift changes needed.
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execFile } = require('child_process');

const KNOWN_KEYS = new Set(['title', 'kind', 'done', 'date', 'start', 'end', 'tags', 'link', 'created', 'source']);

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

/** Thrown when a file changed on disk between when we read it and when we
 * went to write it back — see writeAtomically. */
class StaleWriteError extends Error {
  constructor(filePath) {
    super(`${path.basename(filePath)} changed on disk since it was read`);
    this.name = 'StaleWriteError';
    this.filePath = filePath;
  }
}

function keyOf(line) {
  const trimmed = line.trim();
  if (trimmed.startsWith('#')) return null;
  const idx = line.indexOf(':');
  if (idx === -1) return null;
  return line.slice(0, idx).trim().toLowerCase();
}

function valueOf(line) {
  const idx = line.indexOf(':');
  if (idx === -1) return '';
  return line.slice(idx + 1).trim();
}

function pad2(n) {
  return String(n).padStart(2, '0');
}

// "yyyy-MM-dd" from a Date's LOCAL calendar day (never UTC — this app's
// whole day-bucketing model is local-time).
function dateStringOf(d) {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

function todayString() {
  return dateStringOf(new Date());
}

/**
 * True only for a well-formed AND real "yyyy-MM-dd". Swift's DateFormatter
 * is non-lenient and already rejects 2026-02-31, so the shape check alone
 * would have let JS accept a date the app throws away — exactly the kind of
 * silent divergence the shared fixtures exist to catch.
 */
function isDateString(value) {
  if (typeof value !== 'string' || !DATE_RE.test(value)) return false;
  const [y, m, d] = value.split('-').map(Number);
  if (m < 1 || m > 12 || d < 1) return false;
  // Calendar arithmetic, not `new Date(y, ...)`: that constructor remaps
  // two-digit years to 1900+y, so the round-trip check failed for every
  // year 0001–0099 while Swift's DateFormatter accepted them.
  const isLeap = (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
  const daysInMonth = [31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1];
  return d <= daysInMonth;
}

function shortDateLabel(dateString) {
  const m = DATE_RE.exec(dateString);
  if (!m) return dateString;
  const [y, mo, d] = dateString.split('-').map(Number);
  return new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric' }).format(new Date(y, mo - 1, d));
}

// THE CANONICAL TIME GRAMMAR — kept identical to TaskFile.parseMinutes on
// the Swift side, and pinned by the shared fixtures. Exactly two shapes are
// accepted; everything else is null:
//
//   1. 24-hour "H:mm" / "HH:mm"  — hour 0–23, minute exactly two digits 00–59
//   2. 12-hour "h[:mm] am|pm"    — hour 1–12, optional minutes, optional
//                                  space, optional dots ("3pm", "3:30 p.m.")
//
// Frontmatter is always WRITTEN as shape 1 by both writers; shape 2 exists
// so a hand-typed or voice-derived time still lands correctly.
function parseTimeToMinutes(raw) {
  if (raw == null) return null;
  const trimmed = String(raw).trim();
  if (!trimmed) return null;

  let m = /^(\d{1,2}):(\d{2})$/.exec(trimmed);
  if (m) {
    const h = +m[1];
    const min = +m[2];
    if (h <= 23 && min <= 59) return h * 60 + min;
    return null;
  }

  m = /^(\d{1,2})(?::(\d{2}))?\s*([ap])\.?\s*m\.?$/i.exec(trimmed);
  if (m) {
    const rawHour = +m[1];
    const min = m[2] ? +m[2] : 0;
    // 12-hour clock: only 1–12 is meaningful. "0am"/"15pm" are typos, not times.
    if (rawHour < 1 || rawHour > 12 || min > 59) return null;
    const isPM = m[3].toLowerCase() === 'p';
    const h = (rawHour % 12) + (isPM ? 12 : 0);
    return h * 60 + min;
  }

  return null;
}

function formatMinutesHHmm(minutes) {
  return `${pad2(Math.floor(minutes / 60))}:${pad2(minutes % 60)}`;
}

function formatMinutesDisplay(minutes) {
  const h24 = Math.floor(minutes / 60);
  const min = minutes % 60;
  const ampm = h24 < 12 ? 'AM' : 'PM';
  let h12 = h24 % 12;
  if (h12 === 0) h12 = 12;
  return `${h12}:${pad2(min)} ${ampm}`;
}

// yyyyMMdd-HHmmss in UTC, matching TaskFile.newFilename's stamp exactly.
function utcStamp(date) {
  return (
    `${date.getUTCFullYear()}${pad2(date.getUTCMonth() + 1)}${pad2(date.getUTCDate())}` +
    `-${pad2(date.getUTCHours())}${pad2(date.getUTCMinutes())}${pad2(date.getUTCSeconds())}`
  );
}

function slugify(title) {
  let slug = title
    .toLowerCase()
    .split('')
    .map((ch) => (/[a-z0-9]/.test(ch) ? ch : '-'))
    .join('')
    .replace(/-+/g, '-')
    .replace(/^-+|-+$/g, '');
  if (!slug) slug = 'task';
  return slug.slice(0, 40);
}

function newFilename(title, createdAt) {
  return `${utcStamp(createdAt)}-${slugify(title)}.md`;
}

function isoNoMillis(date) {
  return date.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

/**
 * An identity token for a file's current contents, used as the
 * optimistic-concurrency check in writeAtomically. mtime alone can be
 * reused after a fast rename-into-place, so size and inode ride along.
 */
function signatureOf(stat) {
  return `${stat.mtimeMs}:${stat.size}:${stat.ino}`;
}

function fileSignature(filePath) {
  return signatureOf(fs.statSync(filePath));
}

/**
 * Parses one task file's raw text. Never throws — a malformed file degrades
 * to a filename-titled task rather than being skipped or destroyed.
 *
 * `stat` is optional and passed in by loadAllTasks so a directory scan does
 * one stat per file instead of two. `signature` rides along on the result
 * and is what writeAtomically checks to catch a lost update.
 */
function parseTask(filePath, contents, stat) {
  const id = path.basename(filePath, '.md');
  const normalized = contents.replace(/\r\n/g, '\n');
  const lines = normalized.split('\n');

  let birthtime;
  let signature = null;
  try {
    const st = stat || fs.statSync(filePath);
    birthtime = st.birthtime;
    signature = signatureOf(st);
  } catch {
    birthtime = new Date();
  }

  const base = { id, filePath, signature };

  const fallback = () => ({
    ...base,
    title: id.replace(/[-_]/g, ' ').trim() || id,
    kind: 'task',
    done: false,
    dateString: dateStringOf(birthtime),
    startMinutes: null,
    endMinutes: null,
    tags: [],
    link: null,
    source: null,
    createdAt: birthtime.toISOString(),
    frontmatterLines: null,
    body: normalized,
  });

  if (lines[0]?.trim() !== '---') return fallback();
  let closingIdx = -1;
  for (let i = 1; i < lines.length; i++) {
    if (lines[i].trim() === '---') { closingIdx = i; break; }
  }
  if (closingIdx === -1) return fallback();

  const fmLines = lines.slice(1, closingIdx);
  const body = lines.slice(closingIdx + 1).join('\n');

  let title, kindRaw, done = false, dateRaw, startRaw, endRaw, tagsRaw, linkRaw, createdRaw, sourceRaw;
  for (const line of fmLines) {
    const key = keyOf(line);
    if (!key) continue;
    const value = valueOf(line);
    switch (key) {
      case 'title': title = value; break;
      case 'kind': kindRaw = value; break;
      case 'done': done = value.toLowerCase() === 'true'; break;
      case 'date': dateRaw = value; break;
      case 'start': startRaw = value; break;
      case 'end': endRaw = value; break;
      case 'tags': tagsRaw = value; break;
      case 'link': linkRaw = value; break;
      case 'created': createdRaw = value; break;
      case 'source': sourceRaw = value; break;
    }
  }

  const createdAt = createdRaw && !isNaN(Date.parse(createdRaw)) ? createdRaw : birthtime.toISOString();
  const dateString = isDateString(dateRaw) ? dateRaw : dateStringOf(new Date(createdAt));
  const tags = (tagsRaw || '').split(',').map((s) => s.trim()).filter(Boolean);

  return {
    ...base,
    title: title && title.length ? title : id,
    kind: (kindRaw || '').trim().toLowerCase() === 'meeting' ? 'meeting' : 'task',
    done,
    dateString,
    startMinutes: startRaw ? parseTimeToMinutes(startRaw) : null,
    endMinutes: endRaw ? parseTimeToMinutes(endRaw) : null,
    tags,
    link: linkRaw ? linkRaw.trim() : null,
    source: sourceRaw ? sourceRaw.trim() : null,
    createdAt,
    frontmatterLines: fmLines,
    body,
  };
}

function loadAllTasks(tasksDir) {
  let entries;
  try {
    entries = fs.readdirSync(tasksDir, { withFileTypes: true });
  } catch {
    return [];
  }
  const out = [];
  for (const entry of entries) {
    const name = entry.name;
    if (!name.toLowerCase().endsWith('.md')) continue;
    if (name.startsWith('.')) continue; // our own .<uuid>.tmp scratch files
    const filePath = path.join(tasksDir, name);
    try {
      const stat = fs.statSync(filePath);
      if (!stat.isFile()) continue;
      out.push(parseTask(filePath, fs.readFileSync(filePath, 'utf8'), stat));
    } catch (err) {
      console.error(`[todo-mcp] skipping unreadable file ${name}: ${err.message}`);
    }
  }
  return out;
}

/**
 * Collapses anything that would break the one-key-per-line frontmatter
 * grammar into a single space.
 *
 * Values reach here straight from an LLM via `z.string()`, which happily
 * permits newlines. A title of "Catchup\n---" spliced a second `---` fence
 * into the middle of the frontmatter: everything below it became body text,
 * so a timed, tagged meeting with a `source:` key silently became an
 * untitled task on today — and the tool reported success. `date` was
 * validated against exactly this; every other field was not.
 */
function sanitizeValue(value) {
  return String(value)
    // C0/C1 controls, DEL, NEL, and the Unicode line/paragraph separators.
    // Any of these terminates a line for one parser or the other, and a
    // frontmatter value that spans two lines is a corrupt file.
    .replace(/[\u0000-\u001F\u007F-\u009F\u2028\u2029]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * The single mutation primitive — mirrors TaskFile.setValue exactly.
 *
 * Rewrites the FIRST line matching `key` and deletes any later duplicates,
 * because `parseTask` takes the LAST occurrence of a repeated key. With
 * first-write/last-read, a file that somehow grew two `done:` lines could
 * never be toggled: the write landed on line 1, the read came from line 5,
 * and the checkbox snapped straight back with no error.
 */
function setValue(lines, key, value) {
  const matches = [];
  for (let i = 0; i < lines.length; i++) {
    if (keyOf(lines[i]) === key) matches.push(i);
  }

  if (!matches.length) {
    return value === null ? lines : [...lines, `${key}: ${sanitizeValue(value)}`];
  }

  const first = matches[0];
  const duplicates = new Set(matches.slice(1));
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    if (duplicates.has(i)) continue;
    if (i === first) {
      if (value === null) continue;
      out.push(`${key}: ${sanitizeValue(value)}`);
      continue;
    }
    out.push(lines[i]);
  }
  return out;
}

/** Re-serializes a task, applying `editFn` to its frontmatter lines only —
 * comments, unknown keys, and (unless `newBody` is given) the body all
 * survive untouched. Mirrors TaskFile.applyingEdits. */
function serializeWithEdits(task, editFn, newBody) {
  const base = task.frontmatterLines ?? [];
  const newLines = editFn(base);
  const body = newBody !== undefined ? newBody : task.body;
  if (task.frontmatterLines != null) {
    return '---\n' + newLines.join('\n') + '\n---\n' + body;
  }
  const lines = setValue(newLines, 'created', task.createdAt);
  return '---\n' + lines.join('\n') + '\n---\n' + body;
}

function newFileContents({ title, kind, dateString, startMinutes, endMinutes, tags, link, source, body, createdAt }) {
  // Every frontmatter value goes through sanitizeValue for the same reason
  // setValue does: a newline anywhere in here splices a second `---` fence
  // into the block and the file is born corrupt. The body is exempt — it
  // lives below the fence, where newlines are the whole point.
  const lines = [];
  lines.push(`title: ${sanitizeValue(title)}`);
  if (kind === 'meeting') lines.push('kind: meeting');
  lines.push('done: false');
  lines.push(`date: ${sanitizeValue(dateString)}`);
  if (startMinutes != null) lines.push(`start: ${formatMinutesHHmm(startMinutes)}`);
  if (endMinutes != null) lines.push(`end: ${formatMinutesHHmm(endMinutes)}`);
  const cleanTags = (tags || []).map(sanitizeValue).filter(Boolean);
  if (cleanTags.length) lines.push(`tags: ${cleanTags.join(', ')}`);
  const cleanLink = sanitizeValue(link || '');
  if (cleanLink) lines.push(`link: ${cleanLink}`);
  const cleanSource = sanitizeValue(source || '');
  if (cleanSource) lines.push(`source: ${cleanSource}`);
  lines.push(`created: ${isoNoMillis(createdAt)}`);
  const trimmedBody = body ? `\n${body}` : '';
  return '---\n' + lines.join('\n') + '\n---\n' + trimmedBody;
}

const ENRICHMENT_HEADING = '## Enrichment log';

// Appends one line to a task's "## Enrichment log" section, creating the
// section at the end of the body if it doesn't exist yet. The log is
// always the last thing in the body by convention, so appending is just
// "add a line at the very end" — no need to find/parse an existing section
// to insert into the middle of it.
function appendEnrichmentEntry(body, entry) {
  // Local time, not toISOString(). Everything else in this app buckets by
  // the local calendar day; a UTC stamp here made the provenance line claim
  // the wrong DAY for anyone west of Greenwich.
  const now = new Date();
  const timestamp = `${dateStringOf(now)} ${pad2(now.getHours())}:${pad2(now.getMinutes())}`;
  const line = `- ${timestamp}: ${sanitizeValue(entry)}`;

  // Match the heading as a whole line. A substring test treated "### Enrichment
  // log" (and a passing mention in prose) as the section, and appending to the
  // end of the BODY rather than to the section meant an entry could land under
  // whatever heading the user happened to add afterwards.
  const lines = body.split('\n');
  const headingIndex = lines.findIndex((line) => line.trim() === ENRICHMENT_HEADING);

  if (headingIndex === -1) {
    // Only trailing newlines are stripped — trailing spaces can be a
    // markdown hard line break, which is the author's, not ours to remove.
    const trimmed = body.replace(/\n+$/, '');
    return (trimmed ? `${trimmed}\n\n` : '') + `${ENRICHMENT_HEADING}\n${line}\n`;
  }

  let insertAt = headingIndex + 1;
  while (insertAt < lines.length && /^-\s/.test(lines[insertAt])) insertAt++;
  lines.splice(insertAt, 0, line);
  return lines.join('\n');
}

function uniqueFilePath(tasksDir, filename) {
  let full = path.join(tasksDir, filename);
  if (!fs.existsSync(full)) return full;
  const ext = path.extname(filename);
  const stem = filename.slice(0, -ext.length);
  let counter = 2;
  let candidate;
  do {
    candidate = path.join(tasksDir, `${stem}-${counter}${ext}`);
    counter++;
  } while (fs.existsSync(candidate));
  return candidate;
}

/**
 * Temp-file-then-rename, same reasoning as TaskStore.writeAtomically: the
 * app's poller must never see a half-written file.
 *
 * `expectedMtimeMs` is the optimistic-concurrency check. Both this server
 * and the app do read-modify-write on the WHOLE file from a snapshot, so
 * without it, whichever writer saves second silently erases the other's
 * change. Pass the mtime the task was read at and a concurrent edit becomes
 * a clean StaleWriteError instead of quiet data loss. Omit it for brand-new
 * files, which by definition have nothing to clobber.
 */
function writeAtomically(filePath, contents, expectedSignature) {
  const check = () => {
    if (expectedSignature == null) return;
    let current;
    try {
      current = fileSignature(filePath);
    } catch {
      throw new StaleWriteError(filePath); // deleted out from under us
    }
    // Strict equality, no tolerance window. The previous 1ms of slack was
    // wider than the entire read→write gap inside a tool call (measured at
    // 0.02–0.55ms), so the check could not fire in the situation it exists
    // for. Coarse filesystem timestamps make mtime MORE stable, not less,
    // so the slack bought nothing and cost the whole guarantee.
    if (current !== expectedSignature) throw new StaleWriteError(filePath);
  };

  check();

  const dir = path.dirname(filePath);
  const tmp = path.join(dir, `.${crypto.randomUUID()}.tmp`);
  try {
    fs.writeFileSync(tmp, contents, 'utf8');
    // Re-check with the replacement already staged, so the window between
    // "we looked" and "we swapped" is just the rename syscall itself —
    // which is atomic within a directory.
    check();
    fs.renameSync(tmp, filePath);
  } catch (err) {
    try { fs.unlinkSync(tmp); } catch { /* best effort */ }
    throw err;
  }
}

// Real macOS Trash via Finder, not a permanent delete — same reversibility
// guarantee as the app's own FileManager.trashItem.
//
// The path is passed as an argv value the script reads, never interpolated
// into the script text: AppleScript string escaping is not JSON string
// escaping, and a path is user-influenced data. With `on run argv` there is
// no quoting step to get wrong.
function trashFile(filePath) {
  return new Promise((resolve, reject) => {
    execFile(
      'osascript',
      [
        // The `POSIX file` coercion has to happen OUTSIDE the `tell
        // application "Finder"` block. Inside it, Finder resolves `POSIX
        // file` against its own dictionary, fails to find such an object and
        // raises -1728 ("Can't get POSIX file ...") for every path, including
        // ones that plainly exist. That made delete_task fail 100% of the
        // time. Coerce to an alias first, then hand Finder a real reference.
        '-e', 'on run argv',
        '-e', 'set f to POSIX file (item 1 of argv) as alias',
        '-e', 'tell application "Finder" to delete f',
        '-e', 'end run',
        filePath,
      ],
      (err) => (err ? reject(err) : resolve())
    );
  });
}

module.exports = {
  KNOWN_KEYS,
  DATE_RE,
  StaleWriteError,
  ENRICHMENT_HEADING,
  sanitizeValue,
  signatureOf,
  fileSignature,
  dateStringOf,
  todayString,
  isDateString,
  shortDateLabel,
  parseTimeToMinutes,
  formatMinutesHHmm,
  formatMinutesDisplay,
  slugify,
  newFilename,
  parseTask,
  loadAllTasks,
  setValue,
  serializeWithEdits,
  newFileContents,
  appendEnrichmentEntry,
  uniqueFilePath,
  writeAtomically,
  trashFile,
};
