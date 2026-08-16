// Fuzzy-matches a spoken/typed reference ("the Judith thing", "crimsafe
// catchup") onto a task file. Deliberately conservative: on anything but a
// single confident match, it hands back candidates instead of guessing —
// a wrong `done: true` on a real meeting is worse than one extra turn.
'use strict';

const { formatMinutesDisplay, shortDateLabel } = require('./taskfile');

function resolveTask(tasks, idOrQuery) {
  const q = String(idOrQuery || '').trim();
  if (!q) return { status: 'not_found' };

  const idMatch = tasks.find((t) => t.id === q || t.id === q.replace(/\.md$/i, ''));
  if (idMatch) return { status: 'found', task: idMatch };

  const lower = q.toLowerCase();
  let matches = tasks.filter((t) => t.title.toLowerCase().includes(lower));
  if (matches.length === 0) {
    matches = tasks.filter(
      (t) =>
        t.tags.some((tag) => tag.toLowerCase().includes(lower)) ||
        t.body.toLowerCase().includes(lower)
    );
  }
  if (matches.length === 0) return { status: 'not_found' };
  if (matches.length === 1) return { status: 'found', task: matches[0] };

  matches = matches.slice().sort((a, b) => {
    if (a.dateString !== b.dateString) return a.dateString < b.dateString ? -1 : 1;
    return (a.startMinutes ?? 9999) - (b.startMinutes ?? 9999);
  });
  return { status: 'ambiguous', candidates: matches };
}

function formatTaskLine(t, { showDate = false, includeNotes = false } = {}) {
  const box = t.done ? '[x]' : '[ ]';
  const parts = [box];
  if (showDate) parts.push(shortDateLabel(t.dateString));
  if (t.startMinutes != null) {
    parts.push(
      t.endMinutes != null
        ? `${formatMinutesDisplay(t.startMinutes)}–${formatMinutesDisplay(t.endMinutes)}`
        : formatMinutesDisplay(t.startMinutes)
    );
  }
  parts.push(t.title);
  if (t.tags.length) parts.push(`(${t.tags.join(', ')})`);
  parts.push(`id:${t.id}`);
  let line = parts.join(' ');
  // Full notes text, not a truncated preview — judging whether notes are
  // actually explicit and actionable needs the real content, not a snippet.
  if (includeNotes) {
    const notes = t.body.trim();
    line += notes ? `\n    notes: ${notes.replace(/\n/g, '\n    ')}` : '\n    notes: (none)';
  }
  return line;
}

function formatCandidates(candidates, query) {
  const lines = candidates.map((t) => formatTaskLine(t, { showDate: true }));
  return (
    `Found ${candidates.length} tasks matching "${query}" — ask which one they mean, ` +
    `then call again with the exact id shown:\n${lines.join('\n')}`
  );
}

module.exports = { resolveTask, formatTaskLine, formatCandidates };
