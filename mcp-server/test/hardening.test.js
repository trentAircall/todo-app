// Regression tests for the second round of review findings.
//
// Everything here is a bug that was demonstrated against the real code, not
// a hypothetical. Where a test looks paranoid, assume it is load-bearing.
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const {
  setValue,
  sanitizeValue,
  newFileContents,
  parseTask,
  serializeWithEdits,
  appendEnrichmentEntry,
  ENRICHMENT_HEADING,
} = require('../taskfile');
const { findConflicts, findOverlappingIds, effectiveRange } = require('../planning');
const { resolveTasksDir } = require('../tasksdir');

// ---------------------------------------------------------------------------
// Frontmatter injection
// ---------------------------------------------------------------------------

test('a newline in any frontmatter value cannot break out of its line', () => {
  // Regression: update_task({title: "Catchup\n---"}) spliced a second fence
  // into the frontmatter. Everything below became body text, so a timed,
  // tagged meeting with a source: key silently became an untitled task on
  // today — and the tool reported success.
  const hostile = [
    'Catchup\n---\nrogue: injected',
    'Catchup\r\ndate: 1999-01-01',
    'Catchup date: 1999-01-01',
    'Catchupdone: true',
    'Catchup\tand a tab',
  ];

  for (const title of hostile) {
    const line = setValue([], 'title', title)[0];
    assert.strictEqual(line.split('\n').length, 1, `produced multiple lines for ${JSON.stringify(title)}`);
    assert.doesNotMatch(line, /[\r\u2028\u2029]/, `control character survived in ${JSON.stringify(title)}`);
  }
});

test('an injected title cannot change how the file parses', () => {
  const contents = newFileContents({
    title: 'Catchup\n---\nrogue: injected',
    kind: 'meeting',
    dateString: '2026-09-01',
    startMinutes: 600,
    endMinutes: 660,
    tags: ['external\n---'],
    link: '',
    source: 'gcal:keepme',
    body: 'Prep notes.',
    createdAt: new Date('2026-08-16T12:00:00Z'),
  });

  const task = parseTask('/tmp/injected.md', contents);
  assert.strictEqual(task.kind, 'meeting', 'still a meeting');
  assert.strictEqual(task.dateString, '2026-09-01', 'still on the requested day');
  assert.strictEqual(task.startMinutes, 600, 'still timed');
  assert.strictEqual(task.source, 'gcal:keepme', 'provenance key survives');
  assert.strictEqual((contents.match(/^---$/gm) || []).length, 2, 'exactly two fences');
});

test('sanitizeValue collapses rather than deletes, so text stays readable', () => {
  assert.strictEqual(sanitizeValue('Catchup\n---'), 'Catchup ---');
  assert.strictEqual(sanitizeValue('  spaced   out  '), 'spaced out');
  assert.strictEqual(sanitizeValue('Ünïcödé stays'), 'Ünïcödé stays', 'non-ASCII text is not mangled');
});

// ---------------------------------------------------------------------------
// Duplicate keys
// ---------------------------------------------------------------------------

test('writing a key removes later duplicates of it', () => {
  // Regression: parse takes the LAST occurrence, setValue rewrote the FIRST.
  // A file with two `done:` lines could never be toggled — the write landed
  // on line 1, the read came from line 5, and the checkbox snapped back.
  const lines = ['done: false', 'title: X', 'done: true', 'date: 2026-09-10'];
  const out = setValue(lines, 'done', 'false');
  assert.deepStrictEqual(out, ['done: false', 'title: X', 'date: 2026-09-10']);
  assert.strictEqual(out.filter((l) => l.startsWith('done:')).length, 1);
});

test('deleting a key removes every duplicate', () => {
  const out = setValue(['start: 09:00', 'x: 1', 'start: 10:00'], 'start', null);
  assert.deepStrictEqual(out, ['x: 1']);
});

test('a duplicated key can actually be toggled', () => {
  const fixturePath = path.join(__dirname, '..', '..', 'Tests', 'fixtures', 'files', 'duplicate-keys.md');
  const contents = fs.readFileSync(fixturePath, 'utf8');
  const task = parseTask(fixturePath, contents);
  assert.strictEqual(task.done, true, 'the last occurrence is what the parser sees');

  const written = serializeWithEdits(task, (lines) => setValue(lines, 'done', 'false'));
  const reparsed = parseTask(fixturePath, written);
  assert.strictEqual(reparsed.done, false, 'un-ticking it must actually stick');

  // The other duplicated key is untouched — we only collapse what we write.
  assert.strictEqual((written.match(/^date:/gm) || []).length, 2);
});

// ---------------------------------------------------------------------------
// Enrichment log
// ---------------------------------------------------------------------------

test('entries land inside the log section, not at the end of the body', () => {
  // Regression: the insertion point was always end-of-body, so an entry
  // appended under whatever heading the user had added after the log.
  const body = [
    'Prep notes.',
    '',
    ENRICHMENT_HEADING,
    '- 2026-08-01 09:00: Drive doc linked',
    '',
    '## Action items',
    '- Call Bob back',
    '',
  ].join('\n');

  const out = appendEnrichmentEntry(body, 'Attendees from Calendar');
  const lines = out.split('\n');
  const headingIndex = lines.findIndex((l) => l.trim() === ENRICHMENT_HEADING);
  const actionIndex = lines.findIndex((l) => l.trim() === '## Action items');
  const entryIndex = lines.findIndex((l) => l.includes('Attendees from Calendar'));

  assert.ok(entryIndex > headingIndex, 'entry is below the log heading');
  assert.ok(entryIndex < actionIndex, 'entry is above the next section');
  assert.match(lines[lines.length - 2] || '', /Call Bob back/, "the user's own section stays last");
});

test('an h3 with the same words is not mistaken for the log section', () => {
  const out = appendEnrichmentEntry('### Enrichment log\n- not the real section\n', 'Real entry');
  assert.match(out, /^## Enrichment log$/m, 'a real section is created');
  assert.match(out, /^### Enrichment log$/m, "the user's h3 is left alone");
});

test('a trailing hard line break is preserved', () => {
  const out = appendEnrichmentEntry('line one  \nline two  \n\n', 'x');
  assert.match(out, /line two {2}/, 'two trailing spaces are a markdown hard break, not junk');
});

test('the timestamp uses local time, not UTC', () => {
  // Regression: toISOString() made the provenance line claim the wrong DAY
  // for anyone west of Greenwich, in an app that buckets by local day.
  const out = appendEnrichmentEntry('', 'x');
  const now = new Date();
  const expectedDay = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(
    now.getDate()
  ).padStart(2, '0')}`;
  assert.match(out, new RegExp(`- ${expectedDay} \\d{2}:\\d{2}: x`));
});

// ---------------------------------------------------------------------------
// Conflict / overlap agreement
// ---------------------------------------------------------------------------

test('conflict detection and overlap detection agree about short meetings', () => {
  // Regression: findConflicts used the true length while findOverlappingIds
  // applied a 15-minute floor, so add_task booked 10:10 against a 10:00–10:05
  // item without asking, and week_overview then called them overlapping.
  const existing = { id: 'ping', done: false, dateString: '2026-10-05', startMinutes: 600, endMinutes: 605 };
  const proposed = { id: 'after', done: false, dateString: '2026-10-05', startMinutes: 610, endMinutes: 640 };

  const conflicts = findConflicts([existing], '2026-10-05', proposed.startMinutes, proposed.endMinutes, proposed.id);
  const overlapping = findOverlappingIds([existing, proposed]);

  assert.strictEqual(
    conflicts.length > 0,
    overlapping.size > 0,
    'if one says they clash, so must the other'
  );
});

test('effectiveRange applies the same floor the app uses', () => {
  assert.deepStrictEqual(effectiveRange({ startMinutes: 600, endMinutes: 605 }), { start: 600, end: 615 });
  assert.deepStrictEqual(effectiveRange({ startMinutes: 600, endMinutes: null }), { start: 600, end: 630 });
  assert.strictEqual(effectiveRange({ startMinutes: null }), null);
});

// ---------------------------------------------------------------------------
// Finding the Tasks folder
// ---------------------------------------------------------------------------

// Every case below pins BOTH `pointerFile` and `legacyDefault` at paths
// inside a temp dir. Without that, these tests pass or fail depending on
// whether the machine running them happens to have ~/Developer/To-Do App/
// Tasks — which is exactly how the override bug below reached a real Mac
// after passing in a sandbox.
function hermetic(base, overrides = {}) {
  return {
    env: {},
    serverDir: path.join(base, 'mcp-server'),
    pointerFile: path.join(base, 'no-pointer-file'),
    legacyDefault: path.join(base, 'no-legacy-default'),
    ...overrides,
  };
}

test('a missing Tasks folder is an error, never a newly created decoy', () => {
  // Regression: the server hardcoded an absolute path and mkdirSync'd it, so
  // moving the project (which the README invites) made it recreate an empty
  // folder at the old location. Claude reported an empty calendar and filed
  // every new task into the ghost, silently.
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-resolve-'));
  const missing = path.join(base, 'nowhere', 'Tasks');
  try {
    const result = resolveTasksDir(hermetic(base, { env: { TODO_APP_TASKS_DIR: missing } }));
    assert.ok(result.error, 'must report an error');
    assert.ok(!result.dir, 'must not resolve to anything');
    assert.match(result.error, /TODO_APP_TASKS_DIR/, 'names the thing to fix');
    assert.strictEqual(fs.existsSync(missing), false, 'must not have created the folder');
    assert.strictEqual(fs.existsSync(path.dirname(missing)), false, 'must not have created parents');
  } finally {
    fs.rmSync(base, { recursive: true, force: true });
  }
});

test('a broken override never silently falls back to another folder', () => {
  // Regression: the override was merely FIRST in the candidate list, so
  // pointing it at a bad path fell through to the legacy default. On a
  // machine where that folder exists, the typo vanished and the server
  // quietly used a folder the user hadn't asked for.
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-resolve-'));
  const decoy = path.join(base, 'decoy-that-exists');
  try {
    fs.mkdirSync(decoy);
    const result = resolveTasksDir(
      hermetic(base, {
        env: { TODO_APP_TASKS_DIR: path.join(base, 'typo') },
        legacyDefault: decoy,       // a perfectly good folder, deliberately
        pointerFile: decoy,          // ...and a pointer file's worth of temptation
      })
    );
    assert.ok(result.error, 'a bad override must fail, not redirect');
    assert.ok(!result.dir);
  } finally {
    fs.rmSync(base, { recursive: true, force: true });
  }
});

test('an explicit override wins and is reported as the source', () => {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-resolve-'));
  const dir = path.join(base, 'Tasks');
  try {
    fs.mkdirSync(dir);
    const result = resolveTasksDir(hermetic(base, { env: { TODO_APP_TASKS_DIR: dir } }));
    assert.strictEqual(result.dir, dir);
    assert.match(result.source, /environment variable/);
  } finally {
    fs.rmSync(base, { recursive: true, force: true });
  }
});

test('the pointer file the app writes is preferred over the legacy default', () => {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-resolve-'));
  const moved = path.join(base, 'moved', 'Tasks');
  const legacy = path.join(base, 'legacy');
  const pointer = path.join(base, 'pointer');
  try {
    fs.mkdirSync(moved, { recursive: true });
    fs.mkdirSync(legacy);
    fs.writeFileSync(pointer, `${moved}\n`, 'utf8');
    const result = resolveTasksDir(hermetic(base, { pointerFile: pointer, legacyDefault: legacy }));
    assert.strictEqual(result.dir, moved, 'follows the app wherever it launched from');
    assert.match(result.source, /last launch/);
  } finally {
    fs.rmSync(base, { recursive: true, force: true });
  }
});

test('a sibling Tasks folder is found when running in place', () => {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-resolve-'));
  const serverDir = path.join(base, 'mcp-server');
  const tasksDir = path.join(base, 'Tasks');
  try {
    fs.mkdirSync(serverDir);
    fs.mkdirSync(tasksDir);
    const result = resolveTasksDir(hermetic(base, { serverDir }));
    assert.strictEqual(result.dir, tasksDir);
  } finally {
    fs.rmSync(base, { recursive: true, force: true });
  }
});

test('a file where the Tasks folder should be is not mistaken for one', () => {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-resolve-'));
  const notADir = path.join(base, 'Tasks');
  try {
    fs.writeFileSync(notADir, 'not a directory', 'utf8');
    const result = resolveTasksDir(hermetic(base, { env: { TODO_APP_TASKS_DIR: notADir } }));
    assert.ok(result.error);
  } finally {
    fs.rmSync(base, { recursive: true, force: true });
  }
});

test('nothing anywhere is an error that says what to do about it', () => {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-resolve-'));
  try {
    const result = resolveTasksDir(hermetic(base));
    assert.ok(result.error);
    assert.match(result.error, /Launch the To-Do app once/);
    assert.match(result.error, /TODO_APP_TASKS_DIR/);
  } finally {
    fs.rmSync(base, { recursive: true, force: true });
  }
});
