// End-to-end tests for the MCP tool surface.
//
// conformance.test.js checks the file format in isolation; this file checks
// the tools as Claude actually reaches them — a real server process, real
// JSON-RPC over stdio, real files on disk — against a throwaway Tasks
// folder. Everything the handlers do between "Claude said this" and "a file
// changed" lives in index.js, which unit tests don't reach.
//
// Run with:  npm test
'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const SERVER = path.join(__dirname, '..', 'index.js');

/** A live server process talking MCP over stdio, pointed at a temp folder. */
function startServer() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'todo-mcp-test-'));
  const proc = spawn('node', [SERVER], {
    // TODO_APP_TASKS_DIR is the documented override for the hardcoded path,
    // which is what makes the server testable at all.
    env: { ...process.env, TODO_APP_TASKS_DIR: dir },
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  const pending = new Map();
  let buffer = '';
  proc.stdout.on('data', (chunk) => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline).trim();
      buffer = buffer.slice(newline + 1);
      if (!line) continue;
      const message = JSON.parse(line);
      if (message.id && pending.has(message.id)) {
        pending.get(message.id)(message);
        pending.delete(message.id);
      }
    }
  });

  let nextId = 0;
  const rpc = (method, params) =>
    new Promise((resolve) => {
      const id = ++nextId;
      pending.set(id, resolve);
      proc.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
    });

  return {
    dir,
    rpc,
    async ready() {
      await rpc('initialize', {
        protocolVersion: '2024-11-05',
        capabilities: {},
        clientInfo: { name: 'tools.test.js', version: '1' },
      });
      proc.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' })}\n`);
    },
    /** Calls a tool and returns its text output. */
    async call(name, args) {
      const response = await this.rpc('tools/call', { name, arguments: args });
      assert.ok(response.result, `${name} returned an error: ${JSON.stringify(response.error)}`);
      return response.result.content[0].text;
    },
    /** Reads the one file whose name contains `fragment`. */
    read(fragment) {
      const name = fs.readdirSync(this.dir).find((f) => f.includes(fragment));
      assert.ok(name, `no file matching "${fragment}" in ${this.dir}`);
      return fs.readFileSync(path.join(this.dir, name), 'utf8');
    },
    stop() {
      proc.kill();
      fs.rmSync(dir, { recursive: true, force: true });
    },
  };
}

test('MCP tool surface', async (t) => {
  const server = startServer();
  await server.ready();
  t.after(() => server.stop());

  await t.test('every tool registers', async () => {
    const response = await server.rpc('tools/list', {});
    const names = response.result.tools.map((tool) => tool.name).sort();
    assert.deepStrictEqual(names, [
      'add_task',
      'create_followup',
      'daily_briefing',
      'delete_task',
      'find_free_slots',
      'find_task_by_source',
      'list_tasks',
      'log_enrichment',
      'needs_attention',
      'search_tasks',
      'update_task',
      'week_overview',
    ]);
  });

  await t.test('add_task refuses a date it cannot understand', async () => {
    assert.match(await server.call('add_task', { title: 'X', date: 'someday' }), /Couldn't understand the date/);
    assert.match(await server.call('add_task', { title: 'X', date: '2026-02-31' }), /isn't a real date/);
    assert.match(await server.call('add_task', { title: 'X', date: '15-08-2026' }), /Couldn't understand the date/);
  });

  await t.test('add_task accepts relative days', async () => {
    assert.match(
      await server.call('add_task', { title: 'Tomorrow thing', date: 'tomorrow' }),
      /^Added "Tomorrow thing" on \d{4}-\d{2}-\d{2}\.$/
    );
  });

  await t.test('a 12-hour time is normalized to 24-hour on disk', async () => {
    assert.match(
      await server.call('add_task', {
        title: 'Judith sync',
        kind: 'meeting',
        date: '2026-09-01',
        start: '3pm',
        end: '3:30 pm',
        tags: ['external'],
        notes: 'Prep notes.',
      }),
      /Added "Judith sync" on 2026-09-01 at 3:00 PM/
    );
    const file = server.read('judith');
    assert.match(file, /^start: 15:00$/m);
    assert.match(file, /^end: 15:30$/m);
    assert.match(file, /^kind: meeting$/m);
  });

  await t.test('booking over an existing meeting needs confirmation', async () => {
    assert.match(
      await server.call('add_task', { title: 'Clash', date: '2026-09-01', start: '15:15' }),
      /overlaps something already on 2026-09-01/
    );
    assert.match(
      await server.call('add_task', { title: 'Clash', date: '2026-09-01', start: '15:15', confirm: true }),
      /^Added "Clash"/
    );
  });

  await t.test('update_task refuses a bad date instead of writing it through', async () => {
    // Regression: update_task skipped the yyyy-MM-dd check that add_task
    // had, so `date: "next tuesday"` was written into the file verbatim.
    // Both parsers then rejected it and silently fell back to the creation
    // day — the task teleported to a day nobody chose.
    assert.match(
      await server.call('update_task', { id_or_query: 'Judith sync', date: 'next tuesday' }),
      /Couldn't understand the date/
    );
    const file = server.read('judith');
    assert.match(file, /^date: 2026-09-01$/m, 'the original date is untouched');
    assert.doesNotMatch(file, /next tuesday/, 'the bad value never reached the file');
  });

  await t.test('update_task reschedules and completes', async () => {
    assert.match(
      await server.call('update_task', { id_or_query: 'Judith sync', date: '2026-09-02' }),
      /Updated "Judith sync" \(2026-09-02\)/
    );
    await server.call('update_task', { id_or_query: 'Judith sync', done: true });
    assert.match(server.read('judith'), /^done: true$/m);
  });

  await t.test('an ambiguous reference returns candidates instead of guessing', async () => {
    await server.call('add_task', { title: 'Ambiguous thing', date: '2026-09-03' });
    await server.call('add_task', { title: 'Ambiguous thing', date: '2026-09-04' });

    const candidates = await server.call('update_task', { id_or_query: 'Ambiguous thing', done: true });
    assert.match(candidates, /Found 2 tasks matching/);
    assert.match(candidates, /ask which one/);

    // Deleting is the same: never guess which of two it meant.
    assert.match(await server.call('delete_task', { id_or_query: 'Ambiguous thing' }), /Found 2 tasks matching/);

    // The exact id from the candidate list resolves cleanly.
    const id = candidates.match(/id:(\S+)/)[1];
    assert.match(await server.call('update_task', { id_or_query: id, done: true }), /^Updated "Ambiguous thing"/);
  });

  await t.test('log_enrichment appends without disturbing the notes', async () => {
    await server.call('log_enrichment', { id_or_query: 'Judith sync', entry: 'Drive doc linked: Plan' });
    await server.call('log_enrichment', { id_or_query: 'Judith sync', entry: 'Attendees from Calendar' });

    const file = server.read('judith');
    assert.match(file, /Prep notes\./, 'the original notes survive');
    assert.strictEqual((file.match(/## Enrichment log/g) || []).length, 1, 'one section, not one per entry');
    assert.match(file, /Drive doc linked: Plan/);
    assert.match(file, /Attendees from Calendar/);
    assert.match(file, /^tags: external$/m, 'frontmatter is untouched');
  });

  await t.test('find_free_slots never proposes time outside working hours', async () => {
    const out = await server.call('find_free_slots', {
      duration_minutes: 30,
      date: '2026-09-02',
      work_start: '7:00 am',
      work_end: '7:00 pm',
    });
    for (const line of out.split('\n')) {
      assert.match(line, /^2026-09-02 \d{1,2}:\d{2} (AM|PM)–\d{1,2}:\d{2} (AM|PM)$/);
    }
    assert.doesNotMatch(out, /\b(8|9|10|11):\d{2} PM/, 'nothing after 7pm');
  });

  await t.test('create_followup links back to its source', async () => {
    assert.match(
      await server.call('create_followup', { id_or_query: 'Judith sync' }),
      /Created follow-up "Follow up: Judith sync".*linked back to "Judith sync"/
    );
    const file = server.read('follow-up-judith');
    assert.match(file, /\*\*Follow-up from:\*\* Judith sync/);
    assert.match(file, /^tags: external$/m, 'tags are inherited');
  });

  await t.test('source is a round-trippable idempotency key', async () => {
    assert.match(await server.call('find_task_by_source', { source: 'gcal:xyz' }), /No task found with source/);
    await server.call('add_task', { title: 'Synced event', date: '2026-09-05', source: 'gcal:xyz' });
    assert.match(await server.call('find_task_by_source', { source: 'gcal:xyz' }), /Synced event/);
    assert.match(server.read('synced-event'), /^source: gcal:xyz$/m);
  });

  await t.test('read-only tools report real numbers', async () => {
    const week = await server.call('week_overview', { date: '2026-09-01', days_ahead: 2 });
    assert.match(week, /2026-09-01 \(Tuesday\)/);
    assert.match(week, /h booked/);
    assert.match(await server.call('search_tasks', { query: 'Prep notes' }), /Judith sync/);
    assert.match(await server.call('daily_briefing', { date: 'tomorrow' }), /^Schedule for \d{4}-\d{2}-\d{2}:/);
    assert.match(await server.call('list_tasks', { date: '2026-09-01', end_date: 'whenever' }), /Couldn't understand the date/);
  });

  await t.test('no temp files are left behind', () => {
    assert.deepStrictEqual(fs.readdirSync(server.dir).filter((f) => f.endsWith('.tmp')), []);
    assert.deepStrictEqual(fs.readdirSync(server.dir).filter((f) => f.startsWith('.')), []);
  });
});
