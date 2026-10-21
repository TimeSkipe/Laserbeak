'use strict';

// Архів переписки з сесіями.
//
// Claude Code сам веде транскрипт кожної сесії, але прибирає його через
// 30 днів. На момент написання це 518 МБ і 758 файлів, найстарішому —
// рівно 31 день. Тобто без архіву переписка просто зникає.
//
// Зберігається не сира копія, а дистиляція: репліки користувача й
// відповіді Claude плюс назви використаних інструментів. Службові дані
// (вміст tool_result, підписи міркувань) відкидаються — на реальній
// сесії це дало 4.59 МБ → 0.09 МБ, тобто у 49 разів менше.
//
// Читання інкрементне, від збереженого зсуву: транскрипт великий і
// постійно росте, перечитувати його щоразу було б марно.

const fs = require('fs');
const path = require('path');
const { DATA_DIR } = require('./paths');
const log = require('./log');

const ARCHIVE_DIR = path.join(DATA_DIR, 'archive');
const INDEX_PATH = path.join(ARCHIVE_DIR, 'index.json');

fs.mkdirSync(ARCHIVE_DIR, { recursive: true });

/** sid -> { sid, label, project, projectPath, firstTs, lastTs, messages, offset } */
const index = new Map();

/** sid -> Set<uuid>, підвантажується з архіву за потреби */
const seenUuids = new Map();

let saveTimer = null;

// ---------------------------------------------------------------- індекс

function loadIndex() {
  try {
    const raw = JSON.parse(fs.readFileSync(INDEX_PATH, 'utf8'));
    for (const entry of raw.sessions || []) {
      if (entry?.sid) index.set(entry.sid, entry);
    }
    if (index.size) log.info(`в архіві сесій: ${index.size}`);
  } catch (err) {
    if (err.code !== 'ENOENT') log.warn(`archive/index.json: ${err.message}`);
  }
}

function saveIndex() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    const body = JSON.stringify({ sessions: [...index.values()] }, null, 2);
    fs.writeFile(INDEX_PATH, body, (err) => {
      if (err) log.errorRepeated('archive-index', 'запис archive/index.json', err);
    });
  }, 800);
}

function fileFor(sid) {
  // sid приходить ззовні — не даємо йому вилізти за межі теки архіву.
  const safe = String(sid).replace(/[^A-Za-z0-9._-]/g, '_');
  return path.join(ARCHIVE_DIR, `${safe}.jsonl`);
}

/** Множина вже збережених uuid. Відновлюється з архіву після перезапуску. */
function knownUuids(sid) {
  if (seenUuids.has(sid)) return seenUuids.get(sid);

  const set = new Set();
  try {
    const text = fs.readFileSync(fileFor(sid), 'utf8');
    for (const line of text.split('\n')) {
      if (!line) continue;
      try {
        const uuid = JSON.parse(line).uuid;
        if (uuid) set.add(uuid);
      } catch { /* пошкоджений рядок — пропускаємо */ }
    }
  } catch { /* архіву ще немає */ }

  seenUuids.set(sid, set);
  return set;
}

// ---------------------------------------------------------------- розбір

// Інструменти, якими сесія керує браузером. Потрібні не для архіву, а
// щоб розширення знало, чия це вкладка: коли Claude in Chrome відкриває
// групу вкладок, викликала її саме та сесія, яка щойно тут відзначилась.
//
// Перелік навмисно широкий: браузером керують і через MCP-сервери
// Playwright чи Puppeteer, і зв'язок «вкладка → сесія» від цього не
// залежить.
const BROWSER_TOOL = /claude-in-chrome|playwright|puppeteer|browser/i;

// ---------------------------------------------------------------- що робить

// Остання дія кожної сесії — для острова біля вирізу й смужки на моніторі
// без нього: «редагує server.js». Лише в памʼяті: після перезапуску демона
// приходить із першою ж новою дією, а давні дії нікому не цікаві.
//
// Команду Bash не показуємо: у ній бувають токени й паролі, а острів
// бачить кожен, хто дивиться на екран. Лише опис, який Claude дає їй сам.
const activity = new Map();

// Час останнього запису розмови (репліки людини чи агента) — з нього видно,
// що сесія продовжила роботу після запиту дозволу.
const lastRecord = new Map();

const lastPart = (p) => String(p || '').split('/').filter(Boolean).pop() || '';
const shorten = (s, n = 60) => String(s || '').replace(/\s+/g, ' ').trim().slice(0, n);

function hostOf(url) {
  try { return new URL(url).hostname; } catch { return ''; }
}

/** Блок tool_use → що за дія ({kind}) і над чим ({target}). */
function describeTool(block) {
  const name = String(block.name);
  const input = block.input && typeof block.input === 'object' ? block.input : {};

  if (name.startsWith('mcp__')) {
    if (BROWSER_TOOL.test(name)) return { kind: 'browser', target: '' };
    return { kind: 'tool', target: shorten(name.split('__').pop(), 40) };
  }

  switch (name) {
    case 'Edit':
    case 'MultiEdit': return { kind: 'edit', target: lastPart(input.file_path) };
    case 'NotebookEdit': return { kind: 'edit', target: lastPart(input.notebook_path) };
    case 'Write': return { kind: 'write', target: lastPart(input.file_path) };
    case 'Read': return { kind: 'read', target: lastPart(input.file_path) };
    case 'Bash': return { kind: 'bash', target: shorten(input.description) };
    case 'Grep':
    case 'Glob': return { kind: 'search', target: shorten(input.pattern, 40) };
    case 'WebFetch': return { kind: 'web', target: hostOf(input.url) };
    case 'WebSearch': return { kind: 'websearch', target: shorten(input.query, 40) };
    case 'Task':
    case 'Agent': return { kind: 'agent', target: shorten(input.description || input.subagent_type, 40) };
    case 'TodoWrite': return { kind: 'plan', target: '' };
    case 'AskUserQuestion': return { kind: 'question', target: '' };
    default: return { kind: 'tool', target: shorten(name, 40) };
  }
}

function noteActivity(sid, record) {
  if (record.type !== 'assistant' || !Array.isArray(record.message?.content)) return;
  const at = Date.parse(record.timestamp || '') || Date.now();
  for (const block of record.message.content) {
    if (block?.type !== 'tool_use' || !block.name) continue;
    const prev = activity.get(sid);
    if (!prev || at >= prev.at) activity.set(sid, { ...describeTool(block), at });
  }
}

/** Один запис транскрипту -> одне повідомлення архіву, або null. */
function distill(record) {
  const type = record.type;
  if (type !== 'user' && type !== 'assistant') return null;

  const content = record.message?.content;
  const texts = [];
  const tools = [];

  if (typeof content === 'string') {
    texts.push(content);
  } else if (Array.isArray(content)) {
    for (const block of content) {
      if (!block || typeof block !== 'object') continue;
      if (block.type === 'text' && block.text) texts.push(block.text);
      else if (block.type === 'tool_use' && block.name) tools.push(block.name);
      // thinking і tool_result навмисно не зберігаємо: перше — службове,
      // друге роздуває архів на порядки.
    }
  }

  const text = texts.join('\n').trim();
  if (!text && !tools.length) return null;

  return {
    uuid: record.uuid || '',
    ts: Date.parse(record.timestamp || '') || Date.now(),
    role: type,
    text,
    tools,
    // Підагенти — окрема гілка розмови, у головній стрічці вони зайві.
    sidechain: Boolean(record.isSidechain),
  };
}

// ---------------------------------------------------------------- запис

/**
 * Дочитати транскрипт і дописати нові повідомлення в архів.
 *
 * @param {string} sid
 * @param {string} transcriptPath
 * @param {{label?:string, project?:string, projectPath?:string}} meta
 */
function ingest(sid, transcriptPath, meta = {}) {
  if (!sid || !transcriptPath) return null;

  let entry = index.get(sid);
  if (!entry) {
    entry = {
      sid,
      label: meta.label || '',
      project: meta.project || '',
      projectPath: meta.projectPath || '',
      transcript: transcriptPath,
      firstTs: 0,
      lastTs: 0,
      messages: 0,
      offset: 0,
    };
    index.set(sid, entry);
  }

  // Мітка чи проєкт могли уточнитись пізніше. Зберігаємо одразу, бо
  // нижче можливий ранній вихід — нових повідомлень може й не бути.
  if (meta.label) entry.label = meta.label;
  if (meta.project) entry.project = meta.project;
  if (meta.projectPath) entry.projectPath = meta.projectPath;
  entry.transcript = transcriptPath;
  saveIndex();

  let stat;
  try {
    stat = fs.statSync(transcriptPath);
  } catch {
    return entry;   // транскрипту вже немає
  }

  // Файл підмінили або обрізали — читаємо спочатку.
  if (stat.size < entry.offset) entry.offset = 0;
  if (stat.size === entry.offset) return entry;

  let chunk;
  try {
    const fd = fs.openSync(transcriptPath, 'r');
    const length = stat.size - entry.offset;
    const buffer = Buffer.allocUnsafe(length);
    fs.readSync(fd, buffer, 0, length, entry.offset);
    fs.closeSync(fd);
    chunk = buffer.toString('utf8');
  } catch (err) {
    log.warnRepeated(`archive-read ${sid}`, `архів ${sid.slice(0, 8)}: читання транскрипту ${transcriptPath}`, err);
    return entry;
  }

  // Останній рядок може бути дописаний не до кінця.
  const lastNewline = chunk.lastIndexOf('\n');
  if (lastNewline === -1) return entry;

  const complete = chunk.slice(0, lastNewline + 1);
  entry.offset += Buffer.byteLength(complete, 'utf8');

  const uuids = knownUuids(sid);
  const fresh = [];

  for (const line of complete.split('\n')) {
    if (!line) continue;

    let record;
    try {
      record = JSON.parse(line);
    } catch {
      continue;
    }

    noteActivity(sid, record);

    // Репліки підагентів не рахуємо: підагент може працювати, поки головна
    // сесія чекає на дозвіл.
    if ((record.type === 'user' || record.type === 'assistant') && !record.isSidechain) {
      const at = Date.parse(record.timestamp || '') || 0;
      if (at > (lastRecord.get(sid) || 0)) lastRecord.set(sid, at);
    }

    const message = distill(record);
    if (!message) continue;

    // Той самий запис трапляється у транскрипті не раз.
    if (message.uuid) {
      if (uuids.has(message.uuid)) continue;
      uuids.add(message.uuid);
    }

    // Момент, коли сесія востаннє чіпала браузер. Пишемо в індекс, тому
    // переживає перезапуск демона.
    if (message.tools?.some((name) => BROWSER_TOOL.test(name))) {
      entry.lastBrowserTs = Math.max(entry.lastBrowserTs || 0, message.ts);
    }

    fresh.push(message);
  }

  if (fresh.length) {
    const body = fresh.map((m) => JSON.stringify(m)).join('\n') + '\n';
    try {
      fs.appendFileSync(fileFor(sid), body);
    } catch (err) {
      log.errorRepeated(`archive-write ${sid}`, `архів ${sid.slice(0, 8)}: запис`, err);
      return entry;
    }

    entry.messages += fresh.length;
    entry.lastTs = fresh[fresh.length - 1].ts;
    if (!entry.firstTs) entry.firstTs = fresh[0].ts;
  }

  saveIndex();
  return entry;
}

/**
 * Дочитати всі відомі транскрипти, які нещодавно змінювались.
 *
 * Потрібно тому, що демон дізнається про сесію лише з хука. Після його
 * перезапуску посеред роботи жодна сесія в памʼяті не значиться, і
 * переписка перестала б поповнюватись до наступної події. Індекс архіву
 * памʼятає шляхи транскриптів, тож підхоплюємо їх звідти.
 *
 * @param {number} maxAgeMs наскільки свіжим має бути файл
 */
function ingestRecent(maxAgeMs = 10 * 60_000) {
  const now = Date.now();
  let touched = 0;

  for (const entry of index.values()) {
    if (!entry.transcript) continue;

    let stat;
    try {
      stat = fs.statSync(entry.transcript);
    } catch {
      continue;   // транскрипт уже прибрали
    }

    if (now - stat.mtimeMs > maxAgeMs) continue;
    if (stat.size === entry.offset) continue;

    ingest(entry.sid, entry.transcript, {});
    touched += 1;
  }

  return touched;
}

// ---------------------------------------------------------------- читання

function list() {
  return [...index.values()].sort((a, b) => b.lastTs - a.lastTs);
}

function meta(sid) {
  return index.get(sid) || null;
}

/**
 * Скільки тривала кожна відповідь.
 *
 * Турн — це репліка користувача й усе, що Claude відповів до наступної.
 * Відповідей у турні буває багато (кожен виклик інструмента — окремий
 * запис), тому час чіпляємо до останньої: саме там він і має сенс.
 *
 * Рахуємо в демоні, а не в клієнті: клієнти нічого не обчислюють.
 */
function withReplyTimes(messages) {
  let askedAt = 0;

  // Кінець турна — остання відповідь. Але вішати час на неї «як є» не
  // можна: часто останній запис — це самий лише виклик інструмента, без
  // тексту, а такі в програмі малюються тонким рядком без шапки, і
  // цифра нікому не показалася б.
  //
  // Тому час іде на останню відповідь **із текстом**, а сам відлік — до
  // кінця турна, включно з інструментами після неї.
  let lastAssistant = -1;
  let lastWithText = -1;

  const close = () => {
    if (lastAssistant < 0 || !askedAt) {
      lastAssistant = -1;
      lastWithText = -1;
      return;
    }

    const finishedAt = messages[lastAssistant].ts;
    const target = lastWithText >= 0 ? lastWithText : lastAssistant;
    const seconds = (finishedAt - askedAt) / 1000;

    // Відсіюємо безглузде: годинник міг з'їхати, а запис — прийти з
    // іншого джерела.
    if (seconds > 0 && seconds < 24 * 3600) {
      messages[target] = { ...messages[target], replySeconds: seconds };
    }

    lastAssistant = -1;
    lastWithText = -1;
  };

  for (const [index, message] of messages.entries()) {
    if (message.role === 'user') {
      close();
      askedAt = message.ts;
    } else if (message.role === 'assistant') {
      lastAssistant = index;
      if (message.text) lastWithText = index;
    }
  }

  close();
  return messages;
}

/**
 * Повідомлення сесії.
 * @param {{limit?:number, includeSidechain?:boolean}} options
 */
function read(sid, options = {}) {
  const limit = Number(options.limit) || 0;
  const includeSidechain = Boolean(options.includeSidechain);

  let text;
  try {
    text = fs.readFileSync(fileFor(sid), 'utf8');
  } catch {
    return [];
  }

  const messages = [];
  for (const line of text.split('\n')) {
    if (!line) continue;
    try {
      const message = JSON.parse(line);
      if (!includeSidechain && message.sidechain) continue;
      messages.push(message);
    } catch { /* пошкоджений рядок */ }
  }

  // Час рахуємо до обрізання: інакше в хвості перша відповідь лишилась
  // би без свого запитання й без цифри.
  withReplyTimes(messages);

  return limit > 0 ? messages.slice(-limit) : messages;
}

loadIndex();

/**
 * Коли сесія востаннє користувалась браузером, у мілісекундах.
 * 0 — не користувалась зовсім.
 */
function lastBrowserUse(sid) {
  return index.get(sid)?.lastBrowserTs || 0;
}

/** Коли в розмові сесії зʼявився останній запис, epoch ms; 0 — невідомо. */
function lastRecordAt(sid) {
  return lastRecord.get(sid) || 0;
}

/** Остання дія сесії: { kind, target, at } або null. */
function lastActivity(sid) {
  return activity.get(sid) || null;
}

module.exports = {
  lastBrowserUse, lastActivity, lastRecordAt, describeTool, ingest, ingestRecent, list, meta, read, distill, ARCHIVE_DIR, fileFor };
