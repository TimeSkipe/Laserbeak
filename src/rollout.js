'use strict';

// Rollout-файл Codex — його транскрипт. Архів такий формат не читає, але
// одне питання до нього є: чи пішла сесія далі після запиту дозволу.
//
// Відповідь Codex хуком не повідомляє: наступний хук — Stop, аж у кінці
// ходу, а хід буває й на пів години. Увесь цей час острів і меню-бар
// казали б, що сесія чекає на тебе (бачили 16 хвилин поспіль).
//
// Ознака руху — вихід інструмента чи нова репліка моделі (`response_item`)
// або завершена команда (`event_msg` з `item_completed`). Команда, що чекає
// дозволу, не може ні завершитись, ні дати вихід, тож поки запит висить,
// таких записів немає — хіба що від команди, запущеної паралельно. Службові
// записи на кшталт token_count Codex пише й під час очікування — їх не
// рахуємо.
//
// Файл буває на мегабайти, тож читаємо лише дописане після запиту.

const fs = require('fs');
const path = require('path');
const os = require('os');

const SESSIONS = path.join(process.env.CODEX_HOME || path.join(os.homedir(), '.codex'), 'sessions');

// sid → { file, offset }: з якого байта читати далі.
const tails = new Map();

// Скільки з кінця файлу перечитати, коли початок очікування невідомий.
const RESUME_BYTES = 256 * 1024;

/**
 * Файл сесії: зі шляху, який дав хук, а без нього — за id сесії в імені
 * (rollout-<час>-<sid>.jsonl) у теках за останні три дні.
 */
function locate(sid, hinted) {
  if (hinted && fs.existsSync(hinted)) return hinted;
  for (let back = 0; back < 3; back++) {
    const d = new Date(Date.now() - back * 86_400_000);
    const dir = path.join(SESSIONS, String(d.getFullYear()),
      String(d.getMonth() + 1).padStart(2, '0'), String(d.getDate()).padStart(2, '0'));
    let names;
    try {
      names = fs.readdirSync(dir);
    } catch {
      continue;
    }
    const name = names.find((n) => n.endsWith(`-${sid}.jsonl`));
    if (name) return path.join(dir, name);
  }
  return '';
}

/** Запит дозволу: усе, що допишеться у файл далі, — уже після нього. */
function mark(sid, hinted) {
  const file = locate(sid, hinted);
  if (!file) {
    tails.delete(sid);
    return '';
  }
  tails.set(sid, { file, offset: fs.statSync(file).size });
  return file;
}

/** Чи зʼявився після mark() запис руху, пізніший за `after` (epoch ms). */
function movedOn(sid, after) {
  let tail = tails.get(sid);
  if (!tail) {
    // Демон перезапустили, поки сесія чекала: звідки читати, ніхто не
    // запамʼятав. Беремо хвіст файлу — старше за запит однаково відсіє час.
    const file = locate(sid);
    if (!file) return false;
    tail = { file, offset: Math.max(0, fs.statSync(file).size - RESUME_BYTES) };
    tails.set(sid, tail);
  }

  const size = fs.statSync(tail.file).size;
  if (size <= tail.offset) return false;

  const length = size - tail.offset;
  const buffer = Buffer.alloc(length);
  const fd = fs.openSync(tail.file, 'r');
  try {
    fs.readSync(fd, buffer, 0, length, tail.offset);
  } finally {
    fs.closeSync(fd);
  }

  // Останній рядок може бути дописаний не до кінця — його прочитаємо
  // наступного разу.
  const end = buffer.lastIndexOf(0x0a);
  if (end === -1) return false;
  tail.offset += end + 1;

  for (const line of buffer.subarray(0, end).toString('utf8').split('\n')) {
    if (!line) continue;
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      continue;
    }
    const progress = record.type === 'response_item'
      || (record.type === 'event_msg' && record.payload?.type === 'item_completed');
    if (progress && (Date.parse(record.timestamp || '') || 0) > after) return true;
  }
  return false;
}

function forget(sid) {
  tails.delete(sid);
}

module.exports = { mark, movedOn, forget };
