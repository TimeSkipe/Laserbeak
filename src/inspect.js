'use strict';

// Погляд на систему повз хуки: скільки вкладок термінала відкрито в
// редакторі і скільки процесів Claude живе прямо зараз.
//
// Навіщо це, якщо є хуки: хуки знають лише про сесії, запущені після
// їх установки. Сесія, відкрита раніше, працює, але демон про неї не
// здогадується. Тут вона стає видимою.
//
// Як влаштовано дерево процесів у WebStorm:
//
//   webstorm
//   ├── zsh            ← вкладка термінала
//   │   └── claude     ← сесія Claude Code
//   │       └── zsh    ← інструмент Bash усередині сесії, НЕ вкладка
//   └── zsh            ← ще одна вкладка
//
// Тому вкладкою вважається лише той shell, чий безпосередній батько —
// процес редактора. Інакше в підрахунок потрапили б службові оболонки,
// які Claude Code запускає сам.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile } = require('child_process');
const log = require('./log');

// Тека налаштувань IDE -> ім'я її процесу. Потрібне, щоб не вірити
// прапорцю opened="true" від IDE, яку зараз не запущено: JetBrains
// лишає його у файлі й після виходу.
const IDE_PROCESS = {
  webstorm: 'webstorm',
  intellijidea: 'idea',
  pycharm: 'pycharm',
  pycharmce: 'pycharm',
  phpstorm: 'phpstorm',
  goland: 'goland',
  clion: 'clion',
  rubymine: 'rubymine',
  datagrip: 'datagrip',
  rustrover: 'rustrover',
};

const REFRESH_MS = 4000;

const SHELLS = new Set(['zsh', 'bash', 'fish', 'sh', 'nu']);

// Процеси, дітьми яких бувають вкладки термінала.
const EDITOR_PATTERNS = [
  'webstorm', 'idea', 'pycharm', 'phpstorm', 'goland', 'rubymine', 'clion',
  'code helper', 'electron', 'cursor helper',
];

let latest = {
  at: 0,
  terminals: [],            // [{ pid, cwd, editor, hasClaude }]
  claude: [],               // [{ pid, cwd, ppid }]
  openProjects: new Set(),  // шляхи проєктів, відкритих в IDE прямо зараз
};

let refreshing = false;

function basename(command) {
  const clean = String(command || '').trim();
  const slash = clean.lastIndexOf('/');
  return (slash === -1 ? clean : clean.slice(slash + 1)).toLowerCase();
}

function isEditor(command) {
  const name = basename(command);
  return EDITOR_PATTERNS.some((p) => name.includes(p));
}

function run(file, args) {
  return new Promise((resolve) => {
    execFile(file, args, { timeout: 4000, maxBuffer: 8 * 1024 * 1024 }, (err, stdout) => {
      resolve(err ? '' : String(stdout || ''));
    });
  });
}

/** Таблиця процесів: pid -> { ppid, comm } */
function parseProcesses(text) {
  const table = new Map();

  for (const line of text.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    // pid ppid команда — команда остання і може містити пробіли
    const match = /^(\d+)\s+(\d+)\s+(.*)$/.exec(trimmed);
    if (!match) continue;

    table.set(Number(match[1]), { ppid: Number(match[2]), comm: match[3] });
  }

  return table;
}

/** Робочі каталоги пачки процесів одним викликом lsof. */
async function workingDirs(pids) {
  if (!pids.length) return new Map();

  const out = await run('/usr/sbin/lsof', ['-a', '-d', 'cwd', '-Fpn', '-p', pids.join(',')]);
  const dirs = new Map();
  let current = null;

  for (const line of out.split('\n')) {
    if (line.startsWith('p')) current = Number(line.slice(1));
    else if (line.startsWith('n') && current != null) dirs.set(current, line.slice(1));
  }

  return dirs;
}

/**
 * Проєкти, відкриті в JetBrains IDE прямо зараз.
 *
 * IDE тримає це у recentProjects.xml як атрибут opened="true". Але цей
 * прапорець лишається у файлі й після виходу з IDE, тому враховуємо
 * його лише для тих IDE, чий процес зараз живий.
 */
function openProjects(runningEditors) {
  const home = os.homedir();
  const root = path.join(home, 'Library', 'Application Support', 'JetBrains');
  const found = new Set();

  let dirs;
  try {
    dirs = fs.readdirSync(root);
  } catch {
    return found;   // JetBrains не встановлено
  }

  for (const dir of dirs) {
    // "WebStorm2025.2" -> "webstorm"
    const product = dir.toLowerCase().replace(/[\d.]+$/, '');
    const processName = IDE_PROCESS[product];
    if (!processName || !runningEditors.has(processName)) continue;

    let xml;
    try {
      xml = fs.readFileSync(path.join(root, dir, 'options', 'recentProjects.xml'), 'utf8');
    } catch {
      continue;
    }

    for (const match of xml.matchAll(/<entry key="([^"]+)">([\s\S]*?)<\/entry>/g)) {
      if (!match[2].includes('opened="true"')) continue;

      const key = match[1];
      if (!key.startsWith('$USER_HOME$')) continue;   // light-edit і подібне

      found.add(key.replace('$USER_HOME$', home));
    }
  }

  return found;
}

async function refresh() {
  if (refreshing) return latest;
  refreshing = true;

  try {
    const table = parseProcesses(await run('/bin/ps', ['-eo', 'pid=,ppid=,comm=']));

    const terminals = [];
    const claude = [];
    const runningEditors = new Set();

    for (const [pid, info] of table) {
      const name = basename(info.comm);
      const parent = table.get(info.ppid);

      if (isEditor(info.comm)) runningEditors.add(name);

      if (name === 'claude') {
        claude.push({ pid, ppid: info.ppid });
        continue;
      }

      // Вкладка термінала — shell, чий батько є процесом редактора.
      if (SHELLS.has(name) && parent && isEditor(parent.comm)) {
        terminals.push({ pid, editor: basename(parent.comm) });
      }
    }

    const dirs = await workingDirs([...terminals, ...claude].map((p) => p.pid));

    for (const item of terminals) item.cwd = dirs.get(item.pid) || '';
    for (const item of claude) item.cwd = dirs.get(item.pid) || '';

    // Вкладка вважається зайнятою Claude, якщо процес claude — її прямий
    // нащадок. Так у програмі видно, де просто термінал, а де сесія.
    const shellsWithClaude = new Set(claude.map((c) => c.ppid));
    for (const item of terminals) item.hasClaude = shellsWithClaude.has(item.pid);

    latest = {
      at: Date.now(),
      terminals: terminals.filter((t) => t.cwd),
      claude: claude.filter((c) => c.cwd),
      openProjects: openProjects(runningEditors),
    };
  } catch (err) {
    log.warn(`огляд процесів: ${err.message}`);
  } finally {
    refreshing = false;
  }

  return latest;
}

/**
 * Свіжий знімок без очікування: віддаємо те, що є, і паралельно
 * оновлюємо, якщо дані застаріли. Так /state лишається миттєвим.
 */
function snapshot() {
  if (Date.now() - latest.at > REFRESH_MS) refresh();
  return latest;
}

/** Ті з процесів, що належать каталогу проєкту або його підкаталогу. */
function filterIn(items, projectPath) {
  if (!projectPath) return [];
  const prefix = projectPath.endsWith('/') ? projectPath : projectPath + '/';
  return items.filter((i) => i.cwd === projectPath || i.cwd.startsWith(prefix));
}

function countIn(items, projectPath) {
  return filterIn(items, projectPath).length;
}

module.exports = { snapshot, refresh, filterIn, countIn };
