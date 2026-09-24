'use strict';

// Пам'ять демона: живі сесії, історія подій і зведення по проєктах.

const fs = require('fs');
const path = require('path');
const os = require('os');
const { EVENTS_PATH } = require('./paths');
const config = require('./config');
const projects = require('./projects');
const sessionSettings = require('./sessionSettings');
const tokens = require('./tokens');
const log = require('./log');
const inspect = require('./inspect');
const roots = require('./roots');
const terminals = require('./terminals');
const archive = require('./archive');
const tmux = require('./tmux');
const modes = require('./modes');

const sessions = new Map();
let history = [];
const startedAt = Date.now();

// Живі сесії тримаємо ще й на диску.
//
// Демон дізнається про сесію лише з хука, тож після перезапуску посеред
// роботи він забував би про все відкрите — до наступної події. А ця
// подія може не настати ще довго: сесія просто чекає на тебе.
//
// Мертві записи звідси приберуться самі: демон щопівхвилини перевіряє
// живучість панелей tmux і власних процесів.
const LIVE_PATH = path.join(path.dirname(EVENTS_PATH), 'sessions-live.json');

let liveTimer = null;

function saveLive() {
  clearTimeout(liveTimer);
  liveTimer = setTimeout(() => {
    const body = JSON.stringify({ sessions: [...sessions.values()] }, null, 2);
    fs.writeFile(LIVE_PATH, body, () => {});
  }, 1000);
}

function loadLive() {
  try {
    const raw = JSON.parse(fs.readFileSync(LIVE_PATH, 'utf8'));
    for (const entry of raw.sessions || []) {
      if (entry?.sid) sessions.set(entry.sid, entry);
    }
    if (sessions.size) log.info(`відновлено сесій із диска: ${sessions.size}`);
  } catch (err) {
    if (err.code !== 'ENOENT') log.warn(`sessions-live.json: ${err.message}`);
  }
}

// Що терміновіше, то менше число. Статус проєкту — це статус
// найтерміновішої з його сесій.
const URGENCY = {
  'needs-input': 0,
  waiting: 1,
  working: 2,
  idle: 3,
};

function touch(sid, patch) {
  const prev = sessions.get(sid) || {
    sid,
    label: '?',
    project: '',
    projectPath: '',
    cwd: '',
    term: '',
    editorBundleId: '',
    transcript: '',
    tmuxPane: '',
    pid: 0,
    status: 'idle',
    since: Date.now(),
    turnStartedAt: null,
    lastTurnSeconds: null,
    lastTurnTokens: 0,
    totalWorkSeconds: 0,
    turns: 0,
  };
  const next = { ...prev, ...patch };
  sessions.set(sid, next);
  saveLive();
  return next;
}

function record(entry) {
  const row = { ts: Date.now(), ...entry };
  history.unshift(row);
  const cap = config.get().historySize || 200;
  if (history.length > cap) history.length = cap;
  fs.appendFile(EVENTS_PATH, JSON.stringify(row) + '\n', () => {});
  return row;
}

function decorate(session, now) {
  const custom = sessionSettings.get(session.sid);
  const inTurn = Boolean(session.turnStartedAt);
  const currentTurn = inTurn ? (now - session.turnStartedAt) / 1000 : 0;

  // Дочитуємо транскрипт на льоту: читання інкрементне й із тротлінгом,
  // тому лічильник токенів живий навіть посеред довгого турна.
  const usage = tokens.scan(session.sid, session.transcript);

  // Режим зі смужки й рівень зусиль із ~/.claude/settings.json — це
  // Claude Code. Для Codex вони були б чужими даними, тож порожні.
  const claude = (session.agent || 'claude') === 'claude';

  return {
    ...session,
    // Сесії, збережені до появи Codex, поля не мають — вони всі Claude.
    agent: session.agent || 'claude',
    // Своя назва застосовується тут, на боці демона, тому всі клієнти
    // одразу бачать однакове.
    alias: custom?.alias || '',
    displayName: custom?.alias || session.label,
    notifyEnabled: custom?.notify !== false,
    // Сесію запустив сам Laserbeak — отже, у неї можна писати.
    hosted: terminals.isHosted(session.sid),
    // Або вона працює через tmux у терміналі WebStorm — тоді теж можна.
    canInput: terminals.isHosted(session.sid) || Boolean(session.tmuxPane),
    // Коли сесія востаннє керувала браузером. Розширення бере це, щоб
    // самому зрозуміти, якій сесії належить нова група вкладок.
    lastBrowserUse: archive.lastBrowserUse(session.sid),
    // Режим дозволів Claude Code пише в транскрипт, тож читаємо звідти.
    permissionMode: claude ? modes.read(session) : '',
    // Рівень зусиль видно в тій самій смужці — одним читанням із режимом.
    effort: claude ? modes.readEffort(session) : '',
    tokens: usage,
    ageSeconds: Math.round((now - session.since) / 1000),
    turnSeconds: inTurn ? Math.round(currentTurn) : null,
    // Сумарний час роботи включає турн, який іде просто зараз.
    totalWorkSeconds: Math.round((session.totalWorkSeconds || 0) + currentTurn),
  };
}

/**
 * Найглибший із каталогів, що містить цей шлях.
 * Потрібен, щоб процес у підкаталозі дістався правильному проєкту.
 */
function bestMatch(paths, cwd) {
  if (!cwd) return null;

  let winner = null;
  for (const candidate of paths) {
    const prefix = candidate.endsWith('/') ? candidate : candidate + '/';
    if (cwd !== candidate && !cwd.startsWith(prefix)) continue;
    if (!winner || candidate.length > winner.length) winner = candidate;
  }
  return winner;
}

/**
 * Проєкти = все, що демон коли-небудь бачив, плюс живі сесії, розкладені
 * по своїх проєктах. Проєкт без жодної сесії лишається у списку зі
 * статусом "offline" — так видно всю робочу картину, а не лише відкрите
 * просто зараз.
 */
function buildProjects(liveSessions) {
  const byPath = new Map();

  for (const entry of projects.list()) {
    byPath.set(entry.path, { ...entry, sessions: [] });
  }

  for (const session of liveSessions) {
    // Групуємо за коренем проєкту, а не за робочим каталогом сесії:
    // інакше запуск у підтеці плодив би зайві проєкти.
    const key = session.projectPath || session.cwd || session.project;
    if (!key) continue;

    if (!byPath.has(key)) {
      // Сесія в каталозі, якого немає в реєстрі (реєстр підчистили руками).
      byPath.set(key, {
        path: key,
        name: session.project || key,
        firstSeen: session.since,
        lastSeen: Date.now(),
        editorBundleId: session.editorBundleId || '',
        settings: {},
        sessions: [],
      });
    }
    byPath.get(key).sessions.push(session);
  }

  const processes = inspect.snapshot();

  // Живий процес Claude у незнайомому каталозі — це теж проєкт, просто
  // відкритий до встановлення хуків. Показуємо і його.
  for (const proc of processes.claude) {
    if (!bestMatch([...byPath.keys()], proc.cwd)) {
      const root = roots.resolve(proc.cwd);
      byPath.set(root, {
        path: root,
        name: path.basename(root),
        firstSeen: Date.now(),
        lastSeen: Date.now(),
        editorBundleId: '',
        settings: {},
        sessions: [],
        discovered: true,
      });
    }
  }

  // Кожен процес належить рівно одному проєкту — найглибшому, що його
  // містить. Інакше вкладка в підкаталозі рахувалась би двічі: і для
  // самого підпроєкту, і для батьківського.
  const paths = [...byPath.keys()];
  const counts = new Map(paths.map((p) => [p, { terminals: 0, claudeTerminals: 0, claude: 0 }]));

  for (const terminal of processes.terminals) {
    const owner = bestMatch(paths, terminal.cwd);
    if (!owner) continue;
    counts.get(owner).terminals += 1;
    if (terminal.hasClaude) counts.get(owner).claudeTerminals += 1;
  }

  for (const proc of processes.claude) {
    const owner = bestMatch(paths, proc.cwd);
    if (owner) counts.get(owner).claude += 1;
  }

  return [...byPath.values()].map((p) => {
    const statuses = p.sessions.map((s) => URGENCY[s.status] ?? 3);
    const best = statuses.length ? Math.min(...statuses) : null;
    const status = best == null
      ? 'offline'
      : Object.keys(URGENCY).find((k) => URGENCY[k] === best);

    const live = counts.get(p.path) || { terminals: 0, claudeTerminals: 0, claude: 0 };

    // «Відкритий прямо зараз» = або IDE тримає проєкт відкритим, або в
    // ньому є життя: вкладка термінала, процес Claude чи відома сесія.
    // Решта лишається в реєстрі — просто не показується в списку.
    const isOpen = (processes.openProjects?.has(p.path) ?? false)
      || live.terminals > 0
      || live.claude > 0
      || p.sessions.length > 0;

    return {
      ...p,
      id: p.path,
      status,
      isOpen,
      // Поле має бути завжди, навіть false: клієнти на Swift падають
      // на відсутньому ключі, а не підставляють значення за умовчанням.
      discovered: Boolean(p.discovered),
      sessionCount: p.sessions.length,
      // Усі відкриті вкладки термінала цього проєкту...
      terminals: live.terminals,
      // ...з них ті, де запущено Claude...
      claudeTerminals: live.claudeTerminals,
      // ...і ті, де просто оболонка.
      plainTerminals: live.terminals - live.claudeTerminals,
      claudeProcesses: live.claude,
      // Живі процеси Claude, про які демон не знає: сесію відкрито до
      // встановлення хуків, тож сповіщень від неї не буде.
      untracked: Math.max(0, live.claude - p.sessions.length),
    };
  });
}

/**
 * Адреси цього компʼютера в локальній мережі.
 *
 * Потрібні для QR-коду: телефон сканує його й підключається напряму,
 * коли Bonjour мовчить. Внутрішні та IPv6 відкидаємо — перші нікуди не
 * ведуть із телефона, другі зайві для домашньої мережі.
 */
function lanAddresses() {
  const out = [];

  for (const [name, entries] of Object.entries(os.networkInterfaces())) {
    for (const entry of entries || []) {
      if (entry.internal) continue;
      if (entry.family !== 'IPv4' && entry.family !== 4) continue;
      out.push({ interface: name, address: entry.address });
    }
  }

  // 169.254.x — це link-local: така адреса зʼявляється, наприклад, від
  // телефона, підключеного кабелем. Вона робоча, але для QR потрібна
  // звичайна адреса Wi-Fi, тому такі відсуваємо в кінець.
  const isLinkLocal = (a) => a.address.startsWith("169.254.");

  return out.sort((a, b) => {
    if (isLinkLocal(a) !== isLinkLocal(b)) return isLinkLocal(a) ? 1 : -1;
    return a.interface.localeCompare(b.interface);
  });
}

function snapshot() {
  const now = Date.now();
  const live = [...sessions.values()].map((s) => decorate(s, now));

  return {
    uptimeSeconds: Math.round((now - startedAt) / 1000),
    host: config.get().serviceName,
    port: config.get().port,
    // Клієнт має знати, чи взагалі існує запасний шлях по HTTP:
    // інакше він показував би адресу, яка нікуди не веде.
    bindHost: config.get().bindHost,
    addresses: lanAddresses(),
    projects: buildProjects(live),
    sessions: live.sort((a, b) => a.since - b.since),
    history: history.slice(0, 40),
  };
}

loadLive();

module.exports = {
  sessions,
  touch,
  get: (sid) => sessions.get(sid) || null,
  remove: (sid) => {
    const s = sessions.get(sid);
    sessions.delete(sid);
    saveLive();
    return s;
  },
  record,
  snapshot,
};
