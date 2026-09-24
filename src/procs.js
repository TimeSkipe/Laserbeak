'use strict';

// Звʼязок сесії з її процесом.
//
// Навіщо: перевірка живучості через панель tmux працює лише для сесій,
// запущених через посередника. Сесії, відкриті інакше — наприклад до
// того, як зʼявився tmux у команді start, — лишались у списку назавжди:
// демон не мав жодного способу дізнатись, що їх уже вбили.
//
// Тепер hook.sh передає свій $PPID. Хук запускає сам Claude Code, тож
// піднявшись деревом процесів на пару рівнів, знаходимо той самий
// процес claude. Далі живучість — це просто "чи існує ще цей pid".
//
// Чому не інакше:
//   • ідентифікатора сесії немає в оточенні процесу — перевірено;
//   • транскрипт claude не тримає відкритим, тож через lsof його теж
//     не знайти.

const { execFileSync } = require('child_process');
const log = require('./log');

// Скільки рівнів угору шукати claude. Між хуком і ним зазвичай
// один-два процеси: оболонка, яка запускає сам хук.
const MAX_DEPTH = 6;

// Як звуться процеси агентів. Codex запускає хуки сам, зі свого
// процесу в панелі (MCP-сервери — його прямі нащадки, перевірено), тож
// підйом деревом від $PPID хука знаходить і його.
//
// Лічити живі процеси codex по проєктах, як claude в inspect.js, не
// можна: застосунок ChatGPT тримає купу власних процесів із тим самим
// іменем. Тому codex тут — лише для точного звʼязку «сесія → її pid».
const AGENTS = new Set(['claude', 'codex']);

function processTable() {
  try {
    const out = execFileSync('/bin/ps', ['-eo', 'pid=,ppid=,comm='], {
      encoding: 'utf8',
      timeout: 4000,
      maxBuffer: 8 * 1024 * 1024,
    });

    const table = new Map();
    for (const line of out.split('\n')) {
      const match = /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(line);
      if (!match) continue;
      table.set(Number(match[1]), {
        ppid: Number(match[2]),
        comm: match[3].trim(),
      });
    }
    return table;
  } catch (err) {
    log.warn(`таблиця процесів: ${err.message}`);
    return new Map();
  }
}

function basename(command) {
  const clean = String(command || '').trim();
  const slash = clean.lastIndexOf('/');
  return (slash === -1 ? clean : clean.slice(slash + 1)).toLowerCase();
}

/**
 * Знайти процес агента (claude чи codex), від якого походить цей pid.
 * @returns {number} pid процесу агента, або 0
 */
function nearestAgent(pid) {
  const start = Number(pid);
  if (!start || start <= 1) return 0;

  const table = processTable();
  let current = start;

  for (let depth = 0; depth < MAX_DEPTH; depth += 1) {
    const entry = table.get(current);
    if (!entry) return 0;

    if (AGENTS.has(basename(entry.comm))) return current;

    if (!entry.ppid || entry.ppid <= 1) return 0;
    current = entry.ppid;
  }

  return 0;
}

/**
 * Знайти агента серед нащадків цього процесу.
 * Потрібно для панелей tmux: там відомий pid оболонки, а агент — її дитина.
 */
function agentDescendant(pid) {
  const start = Number(pid);
  if (!start) return 0;

  const table = processTable();

  const children = new Map();
  for (const [child, entry] of table) {
    if (!children.has(entry.ppid)) children.set(entry.ppid, []);
    children.get(entry.ppid).push(child);
  }

  const queue = [start];
  for (let depth = 0; depth < MAX_DEPTH && queue.length; depth += 1) {
    const next = [];
    for (const current of queue) {
      const entry = table.get(current);
      if (entry && AGENTS.has(basename(entry.comm))) return current;
      next.push(...(children.get(current) || []));
    }
    queue.length = 0;
    queue.push(...next);
  }

  return 0;
}

/** Чи живий ще цей процес агента. */
function isAgentAlive(pid) {
  const target = Number(pid);
  if (!target) return false;

  try {
    // Сигнал 0 нічого не робить, лише перевіряє існування процесу.
    process.kill(target, 0);
  } catch {
    return false;
  }

  // Pid могли перевикористати під зовсім інший процес.
  const entry = processTable().get(target);
  return Boolean(entry && AGENTS.has(basename(entry.comm)));
}

module.exports = { nearestAgent, agentDescendant, isAgentAlive, processTable };
