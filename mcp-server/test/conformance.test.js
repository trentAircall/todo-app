// The JavaScript half of the cross-language conformance suite.
//
// Tests/ToDoCoreTests/ParserConformanceTests.swift is the other half, and
// both read the SAME fixtures from Tests/fixtures/. That is the whole point:
// the task file format is implemented twice, so the only thing keeping the
// Swift app and this server able to share a folder is that they agree about
// what a file means. Agreement is checked here, not assumed.
//
// Run with:  npm test
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const {
  parseTimeToMinutes,
  isDateString,
  slugify,
  parseTask,
  serializeWithEdits,
  setValue,
  appendEnrichmentEntry,
  writeAtomically,
  fileSignature,
  StaleWriteError,
  newFilename,
  sanitizeValue,
} = require('../taskfile');
const { findFreeSlots, findOverlappingIds, findConflicts } = require('../planning');

const FIXTURES = path.join(__dirname, '..', '..', 'Tests', 'fixtures');
const cases = JSON.parse(fs.readFileSync(path.join(FIXTURES, 'cases.json'), 'utf8'));

const readFixture = (name) => {
  const filePath = path.join(FIXTURES, 'files', name);
  return { filePath, contents: fs.readFileSync(filePath, 'utf8') };
};

// ---------------------------------------------------------------------------
// Shared fixtures — every case here is also asserted on the Swift side
// ---------------------------------------------------------------------------

test('time grammar matches the shared fixtures', () => {
  for (const c of cases.times) {
    assert.strictEqual(
      parseTimeToMinutes(c.input),
      c.expected,
      `parseTimeToMinutes(${JSON.stringify(c.input)})${c.regression ? ` — regression: ${c.regression}` : ''}`
    );
  }
});

test('date validation matches the shared fixtures', () => {
  for (const c of cases.dates) {
    assert.strictEqual(
      isDateString(c.input),
      c.expected,
      `isDateString(${JSON.stringify(c.input)})${c.regression ? ` — regression: ${c.regression}` : ''}`
    );
  }
});

test('filename slugs match the shared fixtures', () => {
  for (const c of cases.slugs) {
    assert.strictEqual(
      slugify(c.input),
      c.expected,
      `slugify(${JSON.stringify(c.input)})${c.regression ? ` — regression: ${c.regression}` : ''}`
    );
  }
});

test('file parsing matches the shared fixtures', () => {
  for (const c of cases.files) {
    const { filePath, contents } = readFixture(c.file);
    const task = parseTask(filePath, contents);
    const want = c.expected;
    const where = `${c.name} (${c.file})`;

    assert.strictEqual(task.title, want.title, `${where}: title`);
    assert.strictEqual(task.kind, want.kind, `${where}: kind`);
    assert.strictEqual(task.done, want.done, `${where}: done`);
    assert.strictEqual(task.startMinutes, want.startMinutes ?? null, `${where}: startMinutes`);
    assert.strictEqual(task.endMinutes, want.endMinutes ?? null, `${where}: endMinutes`);
    assert.deepStrictEqual(task.tags, want.tags, `${where}: tags`);
    assert.strictEqual(task.frontmatterLines !== null, want.hasFrontmatter, `${where}: hasFrontmatter`);

    // Fields the fixture may legitimately omit: `dateString` is derived from
    // the file's creation time when the frontmatter date is missing/invalid,
    // and `link` isn't meaningful for every case.
    if (want.dateString !== undefined) {
      assert.strictEqual(task.dateString, want.dateString, `${where}: dateString`);
    }
    if (want.link !== undefined) {
      assert.strictEqual(task.link, want.link, `${where}: link`);
    }
    if (want.body !== undefined) {
      assert.strictEqual(task.body, want.body, `${where}: body`);
    }
  }
});

// ---------------------------------------------------------------------------
// The preserve-unknown-data guarantee
// ---------------------------------------------------------------------------

test('an identity edit round-trips a file byte-for-byte', () => {
  for (const c of cases.files) {
    if (!c.expected.hasFrontmatter) continue;
    const { filePath, contents } = readFixture(c.file);
    const task = parseTask(filePath, contents);
    assert.strictEqual(
      serializeWithEdits(task, (lines) => lines),
      contents.replace(/\r\n/g, '\n'),
      `${c.name}: identity edit should be a no-op (line endings normalized)`
    );
  }
});

test('editing one key leaves comments and unknown keys exactly where they were', () => {
  const { filePath, contents } = readFixture('unknown-keys.md');
  const task = parseTask(filePath, contents);
  const out = serializeWithEdits(task, (lines) => setValue(lines, 'done', 'false'));

  assert.match(out, /^# This comment must survive a round-trip untouched\.$/m);
  assert.match(out, /^source: gcal:abc123$/m, 'a key only the MCP server knows');
  assert.match(out, /^x-experimental: something neither side knows$/m, 'a key neither side knows');
  assert.match(out, /^done: false$/m, 'the one key we asked to change');
  assert.doesNotMatch(out, /^done: true$/m);

  // Same line count, and the blank line inside the frontmatter is still there.
  const before = contents.replace(/\r\n/g, '\n').split('\n');
  assert.strictEqual(out.split('\n').length, before.length, 'no lines added or dropped');
});

test('removing a key deletes only that line', () => {
  const { filePath, contents } = readFixture('full-meeting.md');
  const task = parseTask(filePath, contents);
  const out = serializeWithEdits(task, (lines) => setValue(lines, 'link', null));
  assert.doesNotMatch(out, /^link:/m);
  assert.match(out, /^tags: external, crimsafe$/m);
  assert.strictEqual(out.split('\n').length, contents.split('\n').length - 1);
});

test('the enrichment log appends and never rewrites', () => {
  const first = appendEnrichmentEntry('Existing notes.', 'Drive doc linked: Plan');
  assert.match(first, /^Existing notes\.$/m, 'original body survives');
  assert.match(first, /^## Enrichment log$/m);

  const second = appendEnrichmentEntry(first, 'Attendees from Calendar');
  assert.match(second, /^Existing notes\.$/m);
  assert.strictEqual(
    (second.match(/^## Enrichment log$/gm) || []).length,
    1,
    'a second entry reuses the existing section rather than adding another heading'
  );
  assert.match(second, /Drive doc linked: Plan/, 'the earlier entry is still there');
  assert.match(second, /Attendees from Calendar/);
});

// ---------------------------------------------------------------------------
// Regressions
// ---------------------------------------------------------------------------

test('find_free_slots never proposes a window outside working hours', () => {
  // Regression: an event lying wholly outside the work window was clamped
  // into an inverted interval, which the sweep then read as free time. This
  // returned a single 7:00 AM – 7:45 PM "slot" against a 7pm work_end.
  const slots = findFreeSlots(
    [{ id: 'evening', done: false, dateString: '2026-08-20', startMinutes: 20 * 60, endMinutes: 21 * 60 }],
    {
      dates: ['2026-08-20'],
      durationMinutes: 30,
      bufferMinutes: 15,
      workStartMinutes: 7 * 60,
      workEndMinutes: 19 * 60,
      maxResults: 5,
      today: '2026-08-16',
      nowMinutes: 600,
    }
  );
  assert.ok(slots.length > 0, 'a free day should still offer slots');
  for (const slot of slots) {
    assert.ok(slot.startMinutes >= 7 * 60, `slot starts at ${slot.startMinutes}, before work_start`);
    assert.ok(slot.endMinutes <= 19 * 60, `slot ends at ${slot.endMinutes}, after work_end`);
    assert.ok(slot.endMinutes > slot.startMinutes, 'slot is not inverted');
  }
});

test('find_free_slots keeps the buffer around a real meeting', () => {
  const slots = findFreeSlots(
    [{ id: 'standup', done: false, dateString: '2026-08-20', startMinutes: 10 * 60, endMinutes: 11 * 60 }],
    {
      dates: ['2026-08-20'],
      durationMinutes: 30,
      bufferMinutes: 15,
      workStartMinutes: 9 * 60,
      workEndMinutes: 17 * 60,
      maxResults: 10,
      today: '2026-08-16',
      nowMinutes: 0,
    }
  );
  assert.deepStrictEqual(slots, [
    { date: '2026-08-20', startMinutes: 540, endMinutes: 585 },  // 9:00 – 9:45
    { date: '2026-08-20', startMinutes: 675, endMinutes: 1020 }, // 11:15 – 17:00
  ]);
});

test('a done item never blocks a slot or raises a conflict', () => {
  const done = [{ id: 'cancelled', done: true, dateString: '2026-08-20', startMinutes: 600, endMinutes: 660 }];
  assert.strictEqual(findConflicts(done, '2026-08-20', 600, 660, null).length, 0);
  const slots = findFreeSlots(done, {
    dates: ['2026-08-20'],
    durationMinutes: 30,
    bufferMinutes: 15,
    workStartMinutes: 540,
    workEndMinutes: 1020,
    maxResults: 5,
    today: '2026-08-16',
    nowMinutes: 0,
  });
  assert.deepStrictEqual(slots, [{ date: '2026-08-20', startMinutes: 540, endMinutes: 1020 }]);
});

test('overlap detection agrees with the conflict check', () => {
  const items = [
    { id: 'a', startMinutes: 600, endMinutes: 660 },
    { id: 'b', startMinutes: 630, endMinutes: 690 },
    { id: 'c', startMinutes: 700, endMinutes: 730 },
  ];
  assert.deepStrictEqual([...findOverlappingIds(items)].sort(), ['a', 'b']);
});

test('back-to-back meetings do not count as overlapping', () => {
  const items = [
    { id: 'a', startMinutes: 600, endMinutes: 660 },
    { id: 'b', startMinutes: 660, endMinutes: 720 },
  ];
  assert.strictEqual(findOverlappingIds(items).size, 0);
});

test('a stale write is refused instead of clobbering the other writer', async () => {
  // Regression: both writers rewrite the whole file from a snapshot, so
  // whichever saved second silently erased the other's change.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-stale-'));
  const file = path.join(dir, 'task.md');
  try {
    fs.writeFileSync(file, 'original\n', 'utf8');
    const snapshot = fileSignature(file);

    // Someone else edits the file after we read it.
    await new Promise((r) => setTimeout(r, 20));
    fs.writeFileSync(file, 'their change\n', 'utf8');

    assert.throws(
      () => writeAtomically(file, 'our change\n', snapshot),
      StaleWriteError,
      'writing against a stale snapshot must throw'
    );
    assert.strictEqual(fs.readFileSync(file, 'utf8'), 'their change\n', 'their change survives');

    // Writing against the current signature succeeds.
    writeAtomically(file, 'our change\n', fileSignature(file));
    assert.strictEqual(fs.readFileSync(file, 'utf8'), 'our change\n');

    // And a create (no expected signature) is always allowed.
    const fresh = path.join(dir, 'new.md');
    writeAtomically(fresh, 'hello\n');
    assert.strictEqual(fs.readFileSync(fresh, 'utf8'), 'hello\n');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('a concurrent write is caught even with no delay at all', () => {
  // The previous 1ms tolerance was WIDER than the entire read-to-write gap
  // inside a tool call (~0.02-0.55ms), so the check could never fire in the
  // scenario it was written for. No sleep here on purpose: with strict
  // comparison this must still be caught.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-stale-'));
  const file = path.join(dir, 'task.md');
  try {
    let caught = 0;
    const attempts = 50;
    for (let i = 0; i < attempts; i++) {
      fs.writeFileSync(file, `original ${i}\n`, 'utf8');
      const snapshot = fileSignature(file);
      fs.writeFileSync(file, `theirs ${i}\n`, 'utf8'); // immediately, no await
      try {
        writeAtomically(file, `ours ${i}\n`, snapshot);
      } catch (err) {
        if (err instanceof StaleWriteError) caught++;
        else throw err;
      }
    }
    assert.strictEqual(caught, attempts, 'every same-tick concurrent write must be refused');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('a deleted file counts as stale rather than being silently recreated', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-stale-'));
  const file = path.join(dir, 'gone.md');
  try {
    fs.writeFileSync(file, 'x\n', 'utf8');
    const mtime = fs.statSync(file).mtimeMs;
    fs.unlinkSync(file);
    assert.throws(() => writeAtomically(file, 'y\n', mtime), StaleWriteError);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('generated filenames are stable and timezone-independent', () => {
  const at = new Date('2026-08-10T22:17:02Z');
  assert.strictEqual(newFilename('Crimsafe x Aircall Catchup', at), '20260810-221702-crimsafe-x-aircall-catchup.md');
  assert.strictEqual(newFilename('!!!', at), '20260810-221702-task.md');
});
