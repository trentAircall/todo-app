// Finding the one true Tasks/ folder.
//
// This is harder than it looks, and getting it wrong is silent. The app
// resolves its folder relative to the running .app bundle, and the README
// tells the user "move this whole folder anywhere and it keeps working."
// This server used to hardcode an absolute path AND `mkdirSync` it — so
// moving the folder split the two writers: the app followed the move, the
// server recreated an empty decoy at the old path, and Claude cheerfully
// reported an empty calendar while filing new tasks into the ghost.
//
// The fix has two halves:
//   1. The APP writes a pointer file at a stable location every time it
//      launches (see TaskStore.recordTasksFolderLocation). Wherever you
//      move the folder, the next launch re-points the server at it.
//   2. This module never creates a Tasks directory. If it can't find a real
//      one it says so, loudly, in every tool response — the one thing the
//      old code made impossible.
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

/** Written by the Swift app on every launch; read by us on every startup. */
const POINTER_FILE = path.join(
  os.homedir(),
  'Library',
  'Application Support',
  'ToDoApp',
  'tasks-folder-path'
);

/** Last-resort default, for a first run before the app has ever launched. */
const LEGACY_DEFAULT = path.join(os.homedir(), 'Developer', 'To-Do App', 'Tasks');

function isUsableDirectory(candidate) {
  if (!candidate) return false;
  try {
    return fs.statSync(candidate).isDirectory();
  } catch {
    return false;
  }
}

function readPointerFile() {
  try {
    const raw = fs.readFileSync(POINTER_FILE, 'utf8').trim();
    return raw || null;
  } catch {
    return null;
  }
}

/**
 * Resolves the Tasks folder, in priority order:
 *
 *   1. TODO_APP_TASKS_DIR      — explicit override, always wins
 *   2. the pointer file        — wherever the app last launched from
 *   3. ../Tasks from here      — when running in place, un-copied
 *   4. the legacy default path — first run, app never launched
 *
 * Returns `{ dir }` on success, or `{ error }` with an actionable message.
 * Never creates anything.
 */
function resolveTasksDir({ env = process.env, serverDir = __dirname } = {}) {
  const candidates = [
    { source: 'the TODO_APP_TASKS_DIR environment variable', dir: env.TODO_APP_TASKS_DIR },
    { source: 'the location recorded by the app at its last launch', dir: readPointerFile() },
    { source: 'the Tasks folder next to this server', dir: path.join(serverDir, '..', 'Tasks') },
    { source: 'the default project location', dir: LEGACY_DEFAULT },
  ].filter((candidate) => candidate.dir);

  for (const candidate of candidates) {
    if (isUsableDirectory(candidate.dir)) {
      return { dir: path.resolve(candidate.dir), source: candidate.source };
    }
  }

  // An explicit override that doesn't exist is a typo, and deserves a
  // different message from "I looked everywhere and found nothing."
  if (env.TODO_APP_TASKS_DIR) {
    return {
      error:
        `TODO_APP_TASKS_DIR is set to "${env.TODO_APP_TASKS_DIR}", but no folder exists there. ` +
        `Fix the path or unset it to fall back to the location the To-Do app records when it launches.`,
    };
  }

  return {
    error:
      "I can't find the To-Do app's Tasks folder, so I'm not going to guess — creating an empty one " +
      'here would silently split your tasks across two places. Launch the To-Do app once (it records ' +
      'where its Tasks folder lives), or set TODO_APP_TASKS_DIR to the folder’s full path. Looked in: ' +
      candidates.map((c) => c.dir).join(', ') + '.',
  };
}

module.exports = { resolveTasksDir, POINTER_FILE, LEGACY_DEFAULT };
