'use strict';

// stdout перехоплює launchd і пише у ~/.laserbeak/daemon.log
//
// Окремо, в errors.log, лягають лише ⚠ і ✖ — зі стеком, кодом і stderr
// дочірньої програми. У daemon.log одна помилка на тиждень тоне серед
// тисяч «сповіщено»; errors.log одразу відповідає, що зламалось і де.
//
// У daemon.log кожен запис — один рядок. Коментар до скріншота з
// абзацами раніше розривав лог на шматки без часу, і grep їх губив.

const fs = require('fs');
const path = require('path');
const { DATA_DIR, LOG_PATH } = require('./paths');

const ERRORS_PATH = path.join(DATA_DIR, 'errors.log');

// Стеля для кожного файлу; старше переїжджає в .1, і так лише один раз.
const LOG_LIMIT = 5 * 1024 * 1024;
const ERRORS_LIMIT = 1024 * 1024;

// Помилка в таймері повторювалась би кожні дві секунди. Перший раз
// пишемо, далі лише рахуємо й кажемо, скільки їх набралось.
const REPEAT_MS = 10 * 60 * 1000;

// Скільки рядків стека класти в errors.log: далі йдуть кишки Node.
const STACK_LINES = 6;

// Місцевий час, як у app.log. Раніше тут був UTC, і події з двох логів
// розходились на дві-три години — зіставити їх ставало загадкою.
function stamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} `
    + `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

function oneLine(text) {
  return String(text).replace(/\s*\r?\n\s*/g, ' ⏎ ');
}

/** Суть помилки одним рядком: повідомлення, код, stderr програми. */
function describe(err) {
  if (!err) return '';
  if (!(err instanceof Error)) return oneLine(err);

  const parts = [err.message];
  if (err.code && !String(err.message).includes(err.code)) parts.push(`код ${err.code}`);

  const stderr = err.stderr ? String(err.stderr).trim() : '';
  if (stderr) parts.push(`stderr: ${stderr.slice(0, 300)}`);

  return oneLine(parts.join(' · '));
}

function stackOf(err) {
  if (!(err instanceof Error) || !err.stack) return '';
  return err.stack.split('\n').slice(1, 1 + STACK_LINES)
    .map((line) => `    ${line.trim()}\n`).join('');
}

function appendError(line, err) {
  try {
    // 0600: у помилках бувають шляхи й шматки чужих даних, а ~/.laserbeak
    // читає вся група staff.
    fs.appendFileSync(ERRORS_PATH, line + stackOf(err), { mode: 0o600 });
    if (fs.statSync(ERRORS_PATH).size > ERRORS_LIMIT) {
      fs.renameSync(ERRORS_PATH, `${ERRORS_PATH}.1`);
    }
  } catch {
    // Диск повний — саме тоді записати й не вийде. daemon.log уже має рядок.
  }
}

function write(level, msg, err) {
  const detail = describe(err);
  const line = `[${stamp()}] ${level} ${oneLine(msg)}${detail ? `: ${detail}` : ''}\n`;
  process.stdout.write(line);
  if (level !== '·') appendError(line, err);
}

const repeats = new Map();

function throttled(level, key, msg, err) {
  const now = Date.now();
  const seen = repeats.get(key);
  if (seen && now < seen.until) {
    seen.skipped += 1;
    return;
  }

  repeats.set(key, { until: now + REPEAT_MS, skipped: 0 });
  const tail = seen?.skipped ? ` (+${seen.skipped} таких самих за 10 хв)` : '';
  write(level, msg + tail, err);
}

// launchd відкрив daemon.log на дописування (O_APPEND), тож файл можна
// скопіювати й обрізати: наступний рядок ляже з нуля, а не в дірку.
// Обрізаємо лише тоді, коли stdout — справді цей файл, а не термінал.
function rotate() {
  try {
    const out = fs.fstatSync(1);
    const file = fs.statSync(LOG_PATH);
    if (out.ino !== file.ino || file.size <= LOG_LIMIT) return;

    fs.copyFileSync(LOG_PATH, `${LOG_PATH}.1`);
    fs.truncateSync(LOG_PATH, 0);
    write('·', `daemon.log перевищив ${LOG_LIMIT / 1024 / 1024} МБ — попередній у daemon.log.1`);
  } catch {
    // лог в іншому місці або його ще немає — нема чого обрізати
  }
}

rotate();
setInterval(rotate, 10 * 60 * 1000).unref();

module.exports = {
  info: (msg) => write('·', msg),
  warn: (msg, err) => write('⚠', msg, err),
  error: (msg, err) => write('✖', msg, err),

  /** Те саме, але однакові записи з одним `key` — не частіше разу на 10 хв. */
  warnRepeated: (key, msg, err) => throttled('⚠', key, msg, err),
  errorRepeated: (key, msg, err) => throttled('✖', key, msg, err),

  describe,
  ERRORS_PATH,
};
