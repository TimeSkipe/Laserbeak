'use strict';

// Ліміти підписок: скільки використано з 5-годинного й тижневого вікна і
// коли вони скидаються. Без мережі й без токенів — лише те, що агенти самі
// лишають на цьому компʼютері:
//
//   Claude Code  віддає ліміти лише рядку стану (statusLine): rate_limits
//                .five_hour і .seven_day — відсоток і час скидання. На диск
//                їх ніхто не пише, тож hooks/statusline.sh пересилає сюди
//                копію вводу рядка стану (POST /limits/claude), а сам рядок
//                малює твоя команда, як і раніше.
//   Codex        після кожного ходу пише rate_limits у свій rollout-файл
//                (event_msg token_count). Читаємо хвіст найсвіжішого.
//
// Цифри — станом на останній хід на цьому Маку: витрати з claude.ai чи з
// іншого компʼютера видно після наступного ходу тут. Чому не так, як
// OpenUsage (токен із Keychain і запит до API), — docs/decisions.md.

const fs = require('fs');
const path = require('path');
const os = require('os');
const { DATA_DIR } = require('./paths');
const log = require('./log');

// Лише Claude: його цифри приходять тільки з рядка стану, а Codex завжди
// можна перечитати з rollout-файлів.
const SAVED = path.join(DATA_DIR, 'limits.json');

const CODEX_SESSIONS = path.join(process.env.CODEX_HOME || path.join(os.homedir(), '.codex'), 'sessions');
// Тиждень і день: давніший rollout нічого не скаже про чинне вікно.
const CODEX_DAYS = 8;
// Найсвіжіший файл може бути новою сесією без жодного ходу — тоді дивимось
// у кілька попередніх.
const CODEX_FILES = 5;
const TAIL_BYTES = 256 * 1024;
const CODEX_CHECK_MS = 30_000;

// Вікно до доби — «сесійне» (у Codex Plus це 5 годин), довше — тижневе.
const SESSION_MAX_MINUTES = 24 * 60;

// agent → { windows: { session?, weekly? }, updatedAt }, вікно — { used, resetsAt }
const latest = { claude: null, codex: null };
// Найсвіжіший rollout і його mtime: не змінився — нічого не перечитуємо.
let codexSeen = '';

function percent(value) {
  return Math.min(100, Math.max(0, Math.round(value * 10) / 10));
}

function claudeWindow(raw) {
  const used = Number(raw?.used_percentage);
  const resetsAt = Number(raw?.resets_at);
  if (!Number.isFinite(used) || !Number.isFinite(resetsAt) || resetsAt <= 0) return null;
  return { used: percent(used), resetsAt: Math.round(resetsAt) };
}

/**
 * Ввід рядка стану Claude Code. Вікно, якого в ньому немає (Claude Code
 * його не показує, коли воно вже скинулось), лишається таким, як було.
 */
function fromClaude(payload) {
  const raw = payload?.rate_limits;
  if (!raw || typeof raw !== 'object') return;

  const session = claudeWindow(raw.five_hour);
  const weekly = claudeWindow(raw.seven_day);
  if (!session && !weekly) return;

  const windows = { ...(latest.claude?.windows || {}) };
  if (session) windows.session = session;
  if (weekly) windows.weekly = weekly;

  const changed = JSON.stringify(windows) !== JSON.stringify(latest.claude?.windows);
  latest.claude = { windows, updatedAt: Date.now() };
  // Рядок стану оновлюється часто, а цифри — рідко: пишемо лише нове.
  if (changed) save();
}

function save() {
  fs.writeFile(SAVED, JSON.stringify({ claude: latest.claude }, null, 2), (err) => {
    if (err) log.warnRepeated('limits-save', 'ліміти: не записав limits.json', err);
  });
}

function load() {
  try {
    const saved = JSON.parse(fs.readFileSync(SAVED, 'utf8'));
    if (saved?.claude?.windows) latest.claude = saved.claude;
  } catch (err) {
    if (err.code !== 'ENOENT') log.warn('ліміти: limits.json не прочитався', err);
  }
}

function pad(n) {
  return String(n).padStart(2, '0');
}

/** Rollout-файли за останні дні, найсвіжіші першими. */
function recentRollouts() {
  const files = [];
  for (let back = 0; back < CODEX_DAYS; back++) {
    const d = new Date(Date.now() - back * 86_400_000);
    const dir = path.join(CODEX_SESSIONS, String(d.getFullYear()), pad(d.getMonth() + 1), pad(d.getDate()));
    let names;
    try {
      names = fs.readdirSync(dir);
    } catch {
      continue;
    }
    for (const name of names) {
      if (!name.startsWith('rollout-') || !name.endsWith('.jsonl')) continue;
      const file = path.join(dir, name);
      try {
        const st = fs.statSync(file);
        files.push({ file, mtimeMs: st.mtimeMs, size: st.size });
      } catch {
        // файл зник між readdir і stat — пропускаємо
      }
    }
  }
  return files.sort((a, b) => b.mtimeMs - a.mtimeMs);
}

function tail(file, size) {
  const length = Math.min(size, TAIL_BYTES);
  const buffer = Buffer.alloc(length);
  const fd = fs.openSync(file, 'r');
  try {
    fs.readSync(fd, buffer, 0, length, size - length);
  } finally {
    fs.closeSync(fd);
  }
  return buffer.toString('utf8');
}

/** Останній запис із rate_limits у хвості файлу. */
function codexFrom(file, size) {
  const lines = tail(file, size).split('\n');
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i];
    if (!line.includes('"rate_limits"')) continue;
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      continue;   // перший рядок хвоста обрізаний
    }
    const raw = record.payload?.rate_limits;
    // Ліміт самого Codex; окремі ліміти інших моделей тут не потрібні.
    if (!raw || (raw.limit_id && raw.limit_id !== 'codex')) continue;

    const at = Date.parse(record.timestamp || '') || Date.now();
    const windows = {};
    for (const w of [raw.primary, raw.secondary]) {
      const used = Number(w?.used_percent);
      const minutes = Number(w?.window_minutes);
      // Старші версії писали лише resets_in_seconds.
      const resetsAt = Number(w?.resets_at) || (at / 1000 + Number(w?.resets_in_seconds));
      if (!Number.isFinite(used) || !Number.isFinite(minutes) || !Number.isFinite(resetsAt)) continue;
      windows[minutes <= SESSION_MAX_MINUTES ? 'session' : 'weekly'] = {
        used: percent(used),
        resetsAt: Math.round(resetsAt),
      };
    }
    if (Object.keys(windows).length) return { windows, updatedAt: at };
  }
  return null;
}

function refreshCodex() {
  const files = recentRollouts();
  if (!files.length) return;

  const newest = `${files[0].file}:${files[0].mtimeMs}`;
  if (newest === codexSeen) return;
  codexSeen = newest;

  for (const { file, size } of files.slice(0, CODEX_FILES)) {
    const found = codexFrom(file, size);
    if (!found) continue;
    if (!latest.codex || found.updatedAt >= latest.codex.updatedAt) latest.codex = found;
    return;
  }
}

function start() {
  const tick = () => {
    try {
      refreshCodex();
    } catch (e) {
      log.warnRepeated('limits-codex', 'ліміти Codex: rollout не прочитався', e);
    }
  };
  tick();
  setInterval(tick, CODEX_CHECK_MS).unref();
}

/**
 * Для /state. Вікно, що вже скинулось, — нуль використаного, а коли
 * наступне скидання, стане відомо з наступного ходу (resetsAt 0). Агент,
 * у якого скинулось усе, нічого не каже — його немає.
 */
function snapshot(now = Date.now()) {
  const out = [];
  for (const agent of ['claude', 'codex']) {
    const entry = latest[agent];
    if (!entry) continue;

    const windows = [];
    for (const kind of ['session', 'weekly']) {
      const w = entry.windows[kind];
      if (!w) continue;
      windows.push(w.resetsAt * 1000 > now
        ? { kind, used: w.used, resetsAt: w.resetsAt }
        : { kind, used: 0, resetsAt: 0 });
    }
    if (windows.every((w) => w.resetsAt === 0)) continue;
    out.push({ agent, windows, updatedAt: entry.updatedAt });
  }
  return out;
}

load();

module.exports = { fromClaude, refreshCodex, start, snapshot };
