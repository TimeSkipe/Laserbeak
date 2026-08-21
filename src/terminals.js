'use strict';

// Сесії Claude Code, запущені самим Laserbeak.
//
// Чому не можна просто написати в чужий термінал:
//
// stdin живого процесу claude — це псевдотермінал (/dev/ttysNNN), майстер
// якого тримає WebStorm. Вставити туди символи ззовні колись дозволяв
// ioctl TIOCSTI, але macOS його прибрала — його немає навіть у
// заголовках системи. Тобто писати можна лише в той термінал, який
// створив ти сам.
//
// Тому демон уміє запускати claude у власному псевдотерміналі. Такою
// сесією можна керувати з програми: писати запити, бачити відповіді,
// зупиняти.
//
// Ідентифікатор сесії генеруємо самі й передаємо через --session-id, тож
// звʼязок із тим, що потім прилетить із хуків, відомий одразу.

const { spawn, execFileSync } = require('child_process');
const crypto = require('crypto');
const path = require('path');
const fs = require('fs');
const log = require('./log');

// Скільки чекати між текстом і Enter. Одного такту event loop мало:
// Claude Code має встигти прийняти рядок як ввід, а не як вставку.
const ENTER_DELAY_MS = 50;

const BRIDGE = path.join(__dirname, 'pty-bridge.py');

// Скільки останнього виводу тримати для показу й розбору проблем.
const OUTPUT_LIMIT = 64 * 1024;

/** sid -> { sid, label, projectPath, child, startedAt, output, alive, exitCode } */
const hosted = new Map();

function pythonPath() {
  for (const candidate of ['/usr/bin/python3', '/opt/homebrew/bin/python3']) {
    if (fs.existsSync(candidate)) return candidate;
  }
  return 'python3';
}

/**
 * Шлях до claude.
 *
 * У launchd своє врізане PATH, тому просто "claude" не знаходиться.
 * Питаємо оболонку в режимі login + interactive: з одним лише -c zsh не
 * читає .zshrc, а саме там налаштовані nvm та ~/.local/bin.
 *
 * Результат кешуємо: запуск оболонки коштує помітно дорожче за spawn.
 */
let claudeBin = null;

function claudePath() {
  if (claudeBin && fs.existsSync(claudeBin)) return claudeBin;

  try {
    const found = execFileSync('/bin/zsh', ['-lic', 'command -v claude'], {
      encoding: 'utf8',
      timeout: 8000,
    }).trim().split('\n').pop().trim();

    if (found && fs.existsSync(found)) {
      claudeBin = found;
      log.info(`claude знайдено: ${found}`);
      return found;
    }
  } catch (err) {
    log.warn(`пошук claude: ${err.message}`);
  }

  for (const candidate of [
    path.join(process.env.HOME || '', '.local/bin/claude'),
    '/opt/homebrew/bin/claude',
    '/usr/local/bin/claude',
  ]) {
    if (candidate && fs.existsSync(candidate)) {
      claudeBin = candidate;
      return candidate;
    }
  }

  throw new Error('не знайшов claude — перевір, чи він у PATH');
}

/**
 * Запустити нову сесію Claude Code у власному терміналі.
 * @param {{projectPath:string, label?:string, prompt?:string}} options
 */
function start({ projectPath, label = '', prompt = '' }) {
  if (!projectPath || !fs.existsSync(projectPath)) {
    throw new Error('немає такої теки проєкту');
  }

  const sid = crypto.randomUUID();

  const child = spawn(pythonPath(), [BRIDGE, claudePath(), '--session-id', sid], {
    cwd: projectPath,
    env: {
      ...process.env,
      CLAUDE_LABEL: label || path.basename(projectPath),
      TERM: 'xterm-256color',
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  });

  const entry = {
    sid,
    label: label || path.basename(projectPath),
    projectPath,
    child,
    startedAt: Date.now(),
    output: '',
    alive: true,
    exitCode: null,
  };

  const collect = (data) => {
    entry.output += data.toString();
    if (entry.output.length > OUTPUT_LIMIT) {
      entry.output = entry.output.slice(-OUTPUT_LIMIT);
    }
  };

  child.stdout.on('data', collect);
  child.stderr.on('data', collect);

  child.on('error', (err) => {
    entry.alive = false;
    log.error(`сесія ${sid.slice(0, 8)}: ${err.message}`);
  });

  child.on('exit', (code) => {
    entry.alive = false;
    entry.exitCode = code;
    log.info(`сесія ${sid.slice(0, 8)} завершилась (код ${code})`);
  });

  hosted.set(sid, entry);
  log.info(`запущено сесію ${sid.slice(0, 8)} у ${path.basename(projectPath)}`);

  // Перший запит шлемо із затримкою: Claude Code має встигнути
  // намалювати інтерфейс, інакше ввід загубиться.
  if (prompt) {
    setTimeout(() => { try { write(sid, prompt); } catch { /* уже вмерла */ } }, 3000);
  }

  return entry;
}

/** Надіслати текст у сесію так, ніби його набрали з клавіатури. */
function write(sid, text) {
  const entry = hosted.get(sid);
  if (!entry) throw new Error('сесія не належить Laserbeak');
  if (!entry.alive) throw new Error('сесія вже завершилась');

  // Текст і Enter — двома окремими записами, з паузою між ними.
  //
  // Одним шматком це не працює: довгий рядок Claude Code розпізнає як
  // вставку, і \r у тому ж записі стає частиною вставленого тексту, а не
  // відправкою. Запит тихо висить у полі вводу, доки наступний його не
  // виштовхне — і тоді обидва злітають злиплими в один.
  //
  // Коротким текстам щастило, тому дефект довго не було видно. Шлях
  // через tmux його не має взагалі: там `send-keys -l` і `send-keys
  // Enter` — це два окремі виклики.
  entry.child.stdin.write(String(text).replace(/\n+$/, ''));
  setTimeout(() => {
    try { entry.child.stdin.write('\r'); } catch { /* сесія встигла піти */ }
  }, ENTER_DELAY_MS);

  return true;
}

/** Shift+Tab у власну сесію: escape-послідовність зворотного табулятора. */
function shiftTab(sid) {
  const entry = hosted.get(sid);
  if (!entry || !entry.alive) return false;
  entry.child.stdin.write('\x1b[Z');
  return true;
}

/** Ctrl-C у сесію: перервати поточну роботу, не закриваючи її. */
function interrupt(sid) {
  const entry = hosted.get(sid);
  if (!entry || !entry.alive) return false;
  entry.child.stdin.write('\x03');
  return true;
}

function stop(sid) {
  const entry = hosted.get(sid);
  if (!entry) return false;

  try {
    entry.child.stdin.end();
    entry.child.kill('SIGTERM');
  } catch { /* уже мертва */ }

  entry.alive = false;
  return true;
}

function isHosted(sid) {
  return hosted.has(sid) && hosted.get(sid).alive;
}

function get(sid) {
  return hosted.get(sid) || null;
}

function list() {
  return [...hosted.values()].map((e) => ({
    sid: e.sid,
    label: e.label,
    projectPath: e.projectPath,
    startedAt: e.startedAt,
    alive: e.alive,
    exitCode: e.exitCode,
  }));
}

/** Останній вивід термінала без керівних послідовностей. */
function output(sid, limit = 4000) {
  const entry = hosted.get(sid);
  if (!entry) return '';

  const clean = entry.output
    .replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, '')
    .replace(/\x1b\][^\x07]*\x07/g, '')
    .replace(/\r/g, '\n');

  return clean.slice(-limit);
}

function stopAll() {
  for (const sid of hosted.keys()) stop(sid);
}

module.exports = { start, write, shiftTab, interrupt, stop, stopAll, isHosted, get, list, output };
