'use strict';

// Запис у сесії, що працюють у терміналі WebStorm.
//
// Прямо туди написати не можна: майстер псевдотермінала тримає WebStorm,
// а ioctl TIOCSTI, який колись дозволяв вставити символи ззовні, macOS
// прибрала разом із константою в заголовках.
//
// Тому між терміналом і claude ставиться посередник — tmux. Зовні все
// лишається як було: та сама вкладка WebStorm, той самий вигляд, той
// самий ввід з клавіатури. Але тепер у панель можна написати ще й
// ззовні, командою send-keys — і саме це дає запити з телефону.
//
// Адресу панелі (наприклад %3) tmux кладе у змінну TMUX_PANE, а hook.sh
// передає її демону заголовком. Тобто звʼязок сесія → панель відомий,
// щойно з неї прилетить перша подія.

const fs = require('fs');
const { execFile, execFileSync } = require('child_process');
const log = require('./log');

let binary = null;

function tmuxPath() {
  if (binary && fs.existsSync(binary)) return binary;

  for (const candidate of ['/opt/homebrew/bin/tmux', '/usr/local/bin/tmux', '/usr/bin/tmux']) {
    if (fs.existsSync(candidate)) {
      binary = candidate;
      return candidate;
    }
  }

  return null;
}

function isAvailable() {
  return Boolean(tmuxPath());
}

/** Чи жива така панель просто зараз. */
function paneExists(pane) {
  const bin = tmuxPath();
  if (!bin || !pane) return false;

  try {
    const out = execFileSync(bin, ['list-panes', '-a', '-F', '#{pane_id}'], {
      encoding: 'utf8',
      timeout: 3000,
    });
    return out.split('\n').map((s) => s.trim()).includes(pane);
  } catch {
    return false;
  }
}

/**
 * Надіслати текст у панель так, ніби його набрали з клавіатури.
 *
 * Текст і Enter шлемо окремими викликами: інакше tmux може розібрати
 * вміст як назви клавіш і, наприклад, зʼїсти слово "Enter" у запиті.
 * Прапорець -l вимикає таке тлумачення.
 */
function send(pane, text) {
  const bin = tmuxPath();
  if (!bin) throw new Error('tmux не встановлено');
  if (!pane) throw new Error('сесія працює не в tmux');
  if (!paneExists(pane)) throw new Error('панель tmux уже закрита');

  execFileSync(bin, ['send-keys', '-t', pane, '-l', String(text)], { timeout: 5000 });
  execFileSync(bin, ['send-keys', '-t', pane, 'Enter'], { timeout: 5000 });

  return true;
}

/** Shift+Tab — саме нею Claude Code перемикає режим дозволів. */
function shiftTab(pane) {
  const bin = tmuxPath();
  if (!bin || !pane) return false;

  try {
    // BTab — це back-tab, тобто Shift+Tab.
    execFileSync(bin, ['send-keys', '-t', pane, 'BTab'], { timeout: 5000 });
    return true;
  } catch {
    return false;
  }
}

/** Ctrl-C у панель: перервати роботу, не закриваючи сесію. */
function interrupt(pane) {
  const bin = tmuxPath();
  if (!bin || !pane) return false;

  try {
    execFileSync(bin, ['send-keys', '-t', pane, 'C-c'], { timeout: 5000 });
    return true;
  } catch {
    return false;
  }
}

/**
 * Pid процесу, що працює в панелі.
 *
 * Дає точний звʼязок сесія → процес одразу, не чекаючи наступної події
 * від хука. pane_pid — це оболонка панелі; claude запускається як її
 * нащадок, тому шукати треба глибше.
 */
function panePid(pane) {
  const bin = tmuxPath();
  if (!bin || !pane) return 0;

  try {
    const out = execFileSync(bin, ['display-message', '-p', '-t', pane, '#{pane_pid}'], {
      encoding: 'utf8',
      timeout: 3000,
    });
    return Number(out.trim()) || 0;
  } catch {
    return 0;
  }
}

/** Те, що зараз видно в панелі — зручно для перевірки. */
function capture(pane, lines = 40) {
  const bin = tmuxPath();
  if (!bin || !pane) return Promise.resolve('');

  return new Promise((resolve) => {
    execFile(bin, ['capture-pane', '-t', pane, '-p', '-S', `-${lines}`],
      { timeout: 5000, maxBuffer: 1024 * 1024 },
      (err, stdout) => resolve(err ? '' : String(stdout || '')));
  });
}

/** Усі панелі, де зараз працює claude. */
function listPanes() {
  const bin = tmuxPath();
  if (!bin) return [];

  try {
    const out = execFileSync(bin,
      ['list-panes', '-a', '-F', '#{pane_id}\t#{pane_current_command}\t#{pane_current_path}'],
      { encoding: 'utf8', timeout: 3000 });

    return out.split('\n').filter(Boolean).map((line) => {
      const [pane, command, cwd] = line.split('\t');
      return { pane, command, cwd };
    });
  } catch {
    return [];
  }
}

if (!tmuxPath()) {
  log.warn('tmux не знайдено — писати в сесії WebStorm не вийде (brew install tmux)');
}

module.exports = { isAvailable, paneExists, send, shiftTab, interrupt, capture, listPanes, panePid, tmuxPath };
