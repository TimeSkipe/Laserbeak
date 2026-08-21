'use strict';

// Режим дозволів сесії: читання і перемикання.
//
// Звідки беремо поточний режим.
//
// У транскрипті є записи виду
//   {"type":"permission-mode","permissionMode":"auto","sessionId":"…"}
// але вони пишуться на кожен запит користувача, а не на кожну зміну
// режиму. Тобто це режим на момент останньої репліки, а не теперішній.
// На цьому я спершу й помилився: перемикання відбувалось, а перевірка
// його не бачила.
//
// Живе джерело — сам інтерфейс Claude Code, який показує режим у нижній
// смужці: "⏵⏵ auto mode on", "⏸ plan mode on" і так далі. Для сесій у
// tmux це читається через capture-pane, для власних — із виводу
// термінала. Транскрипт лишається запасним варіантом.
//
// Перемикається режим клавішею Shift+Tab по колу. Порядок кола ніде не
// зафіксований і може змінитись із версією, тому ми його не
// припускаємо: тиснемо і щоразу перечитуємо індикатор.
//
// РІВЕНЬ ЗУСИЛЬ читається інакше, і це варто пояснити.
//
// Спокуса була взяти його з тієї ж смужки: нова сесія показує там
// "● high · /effort". Але це **тимчасова підказка новачкові**, а не
// індикатор: у сесії, де вже трохи попрацювали, її немає взагалі.
// Перевірено на живих панелях — там лише рядок режиму.
//
// Тому беремо його з ~/.claude/settings.json, ключ effortLevel. Саме
// туди Claude Code пише вибір: команда /effort каже "saved as your
// default for new sessions". Це значення глобальне, не посесійне —
// тому в інтерфейсі воно й підписане як типове.

const fs = require('fs');
const os = require('os');
const path = require('path');
const tmux = require('./tmux');
const terminals = require('./terminals');
const log = require('./log');

const TAIL_BYTES = 96 * 1024;
const MAX_PRESSES = 8;

// Скільки часу вважати прочитаний режим свіжим. Читання коштує один
// виклик tmux, а /state опитують кожні дві секунди.
const CACHE_MS = 3000;

const KNOWN = ['auto', 'default', 'plan', 'acceptEdits'];

const TITLES = {
  auto: 'авто',
  default: 'звичайний',
  plan: 'планування',
  acceptEdits: 'правки без питань',
  bypassPermissions: 'без обмежень',
};

// Як підписаний режим у смужці -> як він зветься в даних Claude Code.
const INDICATORS = [
  [/\bauto mode on\b/i, 'auto'],
  [/\bmanual mode on\b/i, 'default'],
  [/\bplan mode on\b/i, 'plan'],
  [/\baccept edits on\b/i, 'acceptEdits'],
  [/\bbypass(ing)? permissions on\b/i, 'bypassPermissions'],
];

const EFFORT_LEVELS = ['low', 'medium', 'high', 'xhigh', 'max'];

// Файл, куди Claude Code пише вибраний рівень зусиль.
const SETTINGS_PATH = path.join(os.homedir(), '.claude', 'settings.json');

const EFFORT_TITLES = {
  low: 'низькі',
  medium: 'середні',
  high: 'високі',
  xhigh: 'дуже високі',
  max: 'максимальні',
};

const cache = new Map();   // sid -> { at, mode, effort }

/** Витягти режим із того, що намалював Claude Code. */
function parseIndicator(text) {
  if (!text) return '';

  // Дивимось із кінця: смужка внизу, і там найсвіжіший стан.
  const lines = text.split('\n');
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    for (const [pattern, mode] of INDICATORS) {
      if (pattern.test(lines[i])) return mode;
    }
  }

  return '';
}

// Файл читаємо не частіше, ніж він міг змінитись: /state опитують
// щодві секунди, а перечитувати заради цього json щоразу ні до чого.
let effortCache = { at: 0, value: '' };
const EFFORT_CACHE_MS = 3000;

/**
 * Рівень зусиль із налаштувань Claude Code.
 * Значення глобальне: у самій команді /effort написано, що вибір
 * зберігається як типовий для нових сесій.
 */
function readEffortSetting() {
  if (Date.now() - effortCache.at < EFFORT_CACHE_MS) return effortCache.value;

  let value = '';
  try {
    const raw = JSON.parse(fs.readFileSync(SETTINGS_PATH, 'utf8'));
    if (EFFORT_LEVELS.includes(raw.effortLevel)) value = raw.effortLevel;
  } catch {
    // немає файлу або він зіпсований — просто не показуємо рівень
  }

  effortCache = { at: Date.now(), value };
  return value;
}

/** Запасний шлях: режим на момент останньої репліки. */
function readFromTranscript(transcriptPath) {
  if (!transcriptPath) return '';

  let stat;
  try {
    stat = fs.statSync(transcriptPath);
  } catch {
    return '';
  }

  const start = Math.max(0, stat.size - TAIL_BYTES);

  let text;
  try {
    const fd = fs.openSync(transcriptPath, 'r');
    const length = stat.size - start;
    const buffer = Buffer.allocUnsafe(length);
    fs.readSync(fd, buffer, 0, length, start);
    fs.closeSync(fd);
    text = buffer.toString('utf8');
  } catch {
    return '';
  }

  const lines = text.split('\n');
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    if (!lines[i] || !lines[i].includes('permission-mode')) continue;
    try {
      const record = JSON.parse(lines[i]);
      if (record.type === 'permission-mode' && record.permissionMode) {
        return record.permissionMode;
      }
    } catch { /* обрізаний рядок хвоста */ }
  }

  return '';
}

/**
 * Прочитати смужку просто зараз, без кешу.
 * @returns {Promise<{mode:string, effort:string}>}
 */
async function readNow(session) {
  if (!session) return { mode: '', effort: '' };

  // Одне читання — обидва значення. Смужка одна, і другий capture-pane
  // не дав би нічого нового.
  let text = '';

  if (terminals.isHosted(session.sid)) {
    text = terminals.output(session.sid, 4000);
  } else if (session.tmuxPane) {
    text = await tmux.capture(session.tmuxPane, 12);
  }

  const mode = parseIndicator(text);

  // Транскрипт знає лише про режим, і то застарілий. Беремо його, тільки
  // якщо сесія ще нічого не намалювала.
  return {
    mode: mode || readFromTranscript(session.transcript),
    effort: readEffortSetting(),
  };
}

/**
 * Прочитане зі смужки, для показу. Синхронна: віддає кешоване значення
 * й оновлює його у фоні, щоб /state лишався миттєвим.
 */
function readBoth(session) {
  if (!session?.sid) return { mode: '', effort: '' };

  const hit = cache.get(session.sid);
  if (hit && Date.now() - hit.at < CACHE_MS) return hit;

  // Ставимо мітку одразу, щоб паралельні запити не плодили читань.
  const stale = { at: Date.now(), mode: hit?.mode || '', effort: hit?.effort || '' };
  cache.set(session.sid, stale);

  readNow(session)
    .then(({ mode, effort }) => cache.set(session.sid, { at: Date.now(), mode, effort }))
    .catch(() => {});

  return stale;
}

/** Режим дозволів. */
function read(session) {
  return readBoth(session).mode;
}

/**
 * Рівень зусиль: low | medium | high | xhigh | max.
 *
 * Не залежить від сесії: читається з налаштувань Claude Code і тому
 * однаковий для всіх. Аргумент лишено для симетрії з read().
 */
function readEffort(_session) {
  return readEffortSetting();
}

function forget(sid) {
  cache.delete(sid);
}

/** Забути все: потрібно для примусового оновлення на вимогу. */
function clear() {
  cache.clear();
}

function title(mode) {
  return TITLES[mode] || mode || '';
}

/**
 * Перемкнути режим сесії.
 * @param {{session:object, press:() => void, target:string}} options
 */
async function switchTo({ session, press, target }) {
  if (!KNOWN.includes(target)) {
    throw new Error(`невідомий режим: ${target}`);
  }

  const before = (await readNow(session)).mode;
  if (before === target) return { ok: true, mode: target, presses: 0 };

  for (let attempt = 1; attempt <= MAX_PRESSES; attempt += 1) {
    press();

    // Даємо інтерфейсу перемалюватись.
    await new Promise((resolve) => setTimeout(resolve, 500));

    const now = (await readNow(session)).mode;
    if (now === target) {
      cache.set(session.sid, { at: Date.now(), mode: now, effort: '' });
      log.info(`режим ${before || '?'} → ${target} за ${attempt} натискань`);
      return { ok: true, mode: target, presses: attempt };
    }
  }

  const finalMode = (await readNow(session)).mode;
  cache.set(session.sid, { at: Date.now(), mode: finalMode, effort: '' });
  log.warn(`не вдалося перемкнути на ${target}, лишився ${finalMode || '?'}`);
  return { ok: false, mode: finalMode, presses: MAX_PRESSES };
}

function effortTitle(level) {
  return EFFORT_TITLES[level] || level || '';
}

module.exports = {
  read, readEffort, readEffortSetting, readNow, parseIndicator,
  title, effortTitle, switchTo, forget, clear,
  KNOWN, TITLES, EFFORT_LEVELS, EFFORT_TITLES,
};
