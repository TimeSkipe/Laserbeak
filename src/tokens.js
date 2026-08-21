'use strict';

// Облік токенів живої сесії.
//
// Claude Code веде транскрипт сесії у JSONL, і шлях до нього приходить
// у кожному хуку (`transcript_path`). Кожен запис типу "assistant" несе
// повний usage від API — саме звідти беруться цифри. Нічого вигадувати
// чи оцінювати не треба, це фактичні числа.
//
// Два нюанси, через які наївний підрахунок бреше:
//
//   1. Той самий assistant-запис може бути записаний у файл кілька разів
//      (копії ідентичні). Без дедуплікації за message.id сума завищується
//      приблизно в півтора раза.
//   2. Файл росте постійно і буває великим. Тому читаємо тільки нові
//      байти від збереженого зсуву, а не перечитуємо все щоразу.

const fs = require('fs');
const log = require('./log');

/** sid -> { path, offset, seen:Set<string>, totals } */
const tracked = new Map();

// Не сканувати частіше, ніж раз на стільки мілісекунд для однієї сесії.
const THROTTLE_MS = 1500;

function emptyTotals() {
  return {
    input: 0,        // свіжий контекст, який не потрапив у кеш
    cacheWrite: 0,   // запис у кеш
    cacheRead: 0,    // читання з кешу — зазвичай найбільша частина
    output: 0,
    thinking: 0,     // частина output
    total: 0,
    messages: 0,
    model: '',
  };
}

function ensure(sid, transcriptPath) {
  let entry = tracked.get(sid);

  if (!entry || (transcriptPath && entry.path !== transcriptPath)) {
    entry = {
      path: transcriptPath || entry?.path || '',
      offset: 0,
      seen: new Set(),
      totals: emptyTotals(),
      lastScan: 0,
    };
    tracked.set(sid, entry);
  }

  return entry;
}

function accumulate(entry, record) {
  if (record.type !== 'assistant') return;

  const message = record.message;
  if (!message || typeof message !== 'object') return;

  const usage = message.usage;
  if (!usage) return;

  // Дедуплікація: той самий message.id трапляється у файлі не раз.
  const id = message.id;
  if (id) {
    if (entry.seen.has(id)) return;
    entry.seen.add(id);
  }

  const t = entry.totals;
  t.input += usage.input_tokens || 0;
  t.cacheWrite += usage.cache_creation_input_tokens || 0;
  t.cacheRead += usage.cache_read_input_tokens || 0;
  t.output += usage.output_tokens || 0;
  t.thinking += usage.output_tokens_details?.thinking_tokens || 0;
  t.messages += 1;

  if (message.model) t.model = message.model;

  t.total = t.input + t.cacheWrite + t.cacheRead + t.output;
}

/**
 * Дочитати транскрипт і оновити підсумки.
 * @param {string} sid
 * @param {string} [transcriptPath] шлях із хука; можна не передавати після першого разу
 * @param {boolean} [force] ігнорувати тротлінг (потрібно в кінці турна)
 */
function scan(sid, transcriptPath, force = false) {
  const entry = ensure(sid, transcriptPath);
  if (!entry.path) return entry.totals;

  const now = Date.now();
  if (!force && now - entry.lastScan < THROTTLE_MS) return entry.totals;
  entry.lastScan = now;

  let stat;
  try {
    stat = fs.statSync(entry.path);
  } catch {
    return entry.totals;   // транскрипт ще не створено або вже прибрано
  }

  // Файл зменшився — його переписали. Рахуємо з нуля.
  if (stat.size < entry.offset) {
    entry.offset = 0;
    entry.seen.clear();
    entry.totals = emptyTotals();
  }

  if (stat.size === entry.offset) return entry.totals;

  let chunk;
  try {
    const fd = fs.openSync(entry.path, 'r');
    const length = stat.size - entry.offset;
    const buffer = Buffer.allocUnsafe(length);
    fs.readSync(fd, buffer, 0, length, entry.offset);
    fs.closeSync(fd);
    chunk = buffer.toString('utf8');
  } catch (err) {
    log.warn(`транскрипт ${sid}: ${err.message}`);
    return entry.totals;
  }

  // Останній рядок може бути дописаний не до кінця — лишаємо його
  // на наступний раз, не зсуваючи зсув за нього.
  const lastNewline = chunk.lastIndexOf('\n');
  if (lastNewline === -1) return entry.totals;

  const complete = chunk.slice(0, lastNewline + 1);
  entry.offset += Buffer.byteLength(complete, 'utf8');

  for (const line of complete.split('\n')) {
    if (!line) continue;
    try {
      accumulate(entry, JSON.parse(line));
    } catch {
      // рядок пошкоджений — пропускаємо, решта підрахунку не страждає
    }
  }

  return entry.totals;
}

function get(sid) {
  return tracked.get(sid)?.totals || emptyTotals();
}

function forget(sid) {
  tracked.delete(sid);
}

module.exports = { scan, get, forget, emptyTotals };
