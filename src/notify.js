'use strict';

// Банер macOS. terminal-notifier кращий за osascript: свій заголовок,
// групування (нове сповіщення замінює старе від тієї ж сесії) і клік,
// що повертає в потрібний термінал. osascript — запасний варіант.

const fs = require('fs');
const { spawn, execFile } = require('child_process');
const config = require('./config');
const sessionSettings = require('./sessionSettings');
const projects = require('./projects');
const outbox = require('./outbox');
const log = require('./log');

const CANDIDATES = [
  '/opt/homebrew/bin/terminal-notifier',
  '/usr/local/bin/terminal-notifier',
];

let notifierPath = CANDIDATES.find((p) => fs.existsSync(p)) || null;

// Bundle id термінала, щоб клік по банеру відкрив саме те вікно.
const TERM_BUNDLES = {
  iTerm: 'com.googlecode.iterm2',
  'iTerm.app': 'com.googlecode.iterm2',
  Apple_Terminal: 'com.apple.Terminal',
  vscode: 'com.microsoft.VSCode',
  ghostty: 'com.mitchellh.ghostty',
  WezTerm: 'com.github.wez.wezterm',
  Warp: 'dev.warp.Warp-Stable',
  kitty: 'net.kovidgoyal.kitty',
  WebStorm: 'com.jetbrains.WebStorm',
};

/**
 * Кого активувати при кліку на банер.
 *
 * Найнадійніше джерело — __CFBundleIdentifier, який macOS ставить сама.
 * У терміналі WebStorm змінна TERM_PROGRAM порожня, тож покладатись
 * лише на неї не можна. TERM_PROGRAM лишається запасним варіантом для
 * звичайних терміналів.
 */
function bundleFor({ appBundle, term }) {
  if (appBundle) return appBundle;
  if (!term) return null;
  if (TERM_BUNDLES[term]) return TERM_BUNDLES[term];
  const key = Object.keys(TERM_BUNDLES).find((k) => term.toLowerCase().includes(k.toLowerCase()));
  return key ? TERM_BUNDLES[key] : null;
}

function viaNotifier(n, sound) {
  const args = [
    '-title', n.title,
    '-subtitle', n.subtitle || '',
    '-message', n.message || '',
    '-group', `claude-${n.sid}`,
  ];
  if (sound) args.push('-sound', sound);
  const bundle = bundleFor(n);
  if (bundle) args.push('-activate', bundle);

  const child = spawn(notifierPath, args, { stdio: 'ignore', detached: true });
  child.on('error', (e) => log.error(`terminal-notifier: ${e.message}`));
  child.unref();
}

function viaOsascript(n, sound) {
  const esc = (s) => String(s || '').replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  const snd = sound ? ` sound name "${esc(sound)}"` : '';
  execFile('/usr/bin/osascript', ['-e',
    `display notification "${esc(n.message)}" with title "${esc(n.title)}" subtitle "${esc(n.subtitle)}"${snd}`,
  ], { timeout: 3000 }, (err) => { if (err) log.error(`osascript: ${err.message}`); });
}

/**
 * Показати сповіщення.
 *
 * Головний шлях — сама програма Laserbeak: демон кладе подію в чергу,
 * програма миттєво її забирає і показує від свого імені, зі своєю
 * іконкою в Центрі сповіщень.
 *
 * Якщо програму закрито, працює запасний шлях через terminal-notifier —
 * щоб сповіщення не зникли зовсім.
 *
 * @param {{kind,sid,title,subtitle,message,term,project,appBundle}} n
 */
function send(n) {
  const cfg = config.get();

  if (cfg.notify[n.kind] === false) {
    log.info(`тихо [${n.kind}] ${n.subtitle}: вимкнено в config.notify`);
    return;
  }

  // Вимикач сповіщень конкретної сесії — сильніший за загальне правило.
  // За замовчуванням сповіщення увімкнені: вимкненими вони стають лише
  // тоді, коли їх свідомо вимкнули у вікні програми.
  if (!sessionSettings.isNotifyEnabled(n.sid)) {
    log.info(`тихо [${n.kind}] ${n.subtitle}: сповіщення цієї сесії вимкнені`);
    return;
  }

  const sound = cfg.sounds?.[n.kind] || '';

  if (outbox.hasDesktopClient()) {
    // Колір та іконка проєкту йдуть у банер, щоб він упізнавався
    // з першого погляду, без читання тексту.
    const look = projects.settingsFor(n.cwd);

    outbox.push({
      kind: n.kind,
      sid: n.sid,
      session: n.subtitle,
      project: n.project || '',
      color: look.color || '',
      icon: look.icon || '',
      message: n.message,
      sound,
      appBundle: bundleFor(n) || '',
    });
    log.info(`сповіщено [${n.kind}] ${n.subtitle} → Laserbeak`);
    return;
  }

  if (notifierPath) viaNotifier(n, sound);
  else viaOsascript(n, sound);

  log.info(`сповіщено [${n.kind}] ${n.subtitle} → terminal-notifier (програму закрито)`);
}

module.exports = {
  send,
  isNotifierInstalled: () => Boolean(notifierPath),
  notifierPath: () => notifierPath,
};
