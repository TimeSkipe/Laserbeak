'use strict';

// Прибирання мертвих сесій.
//
// Хук SessionEnd прилітає при звичайному виході, але якщо вкладку вбити
// або закрити вікно WebStorm, він не спрацює — і сесія висіла б у списку
// вічно.
//
// Сигнали, від найточнішого до найслабшого:
//
//   1. власна сесія демона — стан дочірнього процесу;
//   2. pid процесу claude — його передає hook.sh через $PPID;
//   3. панель tmux — існує вона чи ні;
//   4. кількість живих процесів claude у проєкті.
//
// Четвертий потрібен для сесій, відкритих до появи перших трьох: вони
// вже не шлють подій, тож pid у них ніколи не зʼявиться. Якщо в проєкті
// не лишилось жодного процесу claude, усі його неопізнані сесії мертві —
// це вже не здогад.
//
// Коли процесів менше, ніж неопізнаних сесій, зайві теж прибираються,
// починаючи з найдавніших. Тут можлива помилка, але вона нешкідлива:
// жива сесія повернеться у список із наступною ж подією.

const state = require('./state');
const terminals = require('./terminals');
const tmux = require('./tmux');
const modes = require('./modes');
const procs = require('./procs');
const inspect = require('./inspect');
const roots = require('./roots');
const log = require('./log');

/**
 * Для сесій у tmux pid можна дізнатись одразу, не чекаючи події від
 * хука: панель знає свою оболонку, а claude — її нащадок.
 */
function fillPidFromPane(session) {
  if (session.pid || !session.tmuxPane) return;
  if (!tmux.paneExists(session.tmuxPane)) return;

  const shell = tmux.panePid(session.tmuxPane);
  const pid = shell ? procs.claudeDescendant(shell) : 0;
  if (pid) state.touch(session.sid, { pid });
}

/** Точна відповідь про сесію, або null якщо певності немає. */
function definiteVerdict(session) {
  if (terminals.get(session.sid)) return terminals.isHosted(session.sid);
  if (session.pid) return procs.isClaudeAlive(session.pid);
  if (session.tmuxPane) return tmux.paneExists(session.tmuxPane);
  return null;
}

function drop(session, reason, removed) {
  state.remove(session.sid);
  modes.forget(session.sid);

  state.record({
    sid: session.sid,
    label: session.label,
    project: session.project,
    kind: 'session-end',
    message: 'сесія зникла (термінал закрито)',
  });

  log.info(`прибрав мертву сесію ${session.label} (${session.sid.slice(0, 8)}): ${reason}`);
  removed.push({ sid: session.sid, label: session.label, project: session.project });
}

/**
 * Перевірити всі відомі сесії й прибрати ті, що вже не живі.
 * @returns {Array<{sid:string, label:string, project:string}>} прибрані
 */
function reap() {
  const removed = [];
  const unknown = [];

  for (const session of [...state.sessions.values()]) {
    fillPidFromPane(session);
    const verdict = definiteVerdict(state.get(session.sid) || session);

    if (verdict === false) {
      drop(session, 'процес не знайдено', removed);
    } else if (verdict === null) {
      unknown.push(session);
    }
  }

  if (!unknown.length) return removed;

  // ---- слабший сигнал: скільки процесів claude живе в кожному проєкті

  const processes = inspect.snapshot().claude || [];

  const liveByProject = new Map();
  for (const proc of processes) {
    const root = roots.resolve(proc.cwd);
    liveByProject.set(root, (liveByProject.get(root) || 0) + 1);
  }

  // Сесії, у яких точний сигнал є, вже займають свої процеси.
  for (const session of state.sessions.values()) {
    if (unknown.includes(session)) continue;
    const root = session.projectPath || session.cwd;
    if (liveByProject.has(root)) {
      liveByProject.set(root, Math.max(0, liveByProject.get(root) - 1));
    }
  }

  const byProject = new Map();
  for (const session of unknown) {
    const root = session.projectPath || session.cwd || '';
    if (!byProject.has(root)) byProject.set(root, []);
    byProject.get(root).push(session);
  }

  for (const [root, list] of byProject) {
    const available = liveByProject.get(root) || 0;
    if (list.length <= available) continue;

    // Найдавніші за активністю — найімовірніші кандидати на смерть.
    const ordered = [...list].sort((a, b) => {
      const aSeen = a.turnStartedAt || a.since || 0;
      const bSeen = b.turnStartedAt || b.since || 0;
      return aSeen - bSeen;
    });

    const excess = list.length - available;
    for (let i = 0; i < excess; i += 1) {
      drop(ordered[i], `у проєкті лишилось процесів claude: ${available}`, removed);
    }
  }

  return removed;
}

module.exports = { reap };
