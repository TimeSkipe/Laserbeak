'use strict';

// Чи є на GitHub новіша версія Laserbeak — і як на неї перейти.
//
// Програму збирають на тій машині, де нею користуються, тож ця копія
// репозиторію і є встановлена версія, а її HEAD — номер версії. Питання
// «чи є оновлення» зводиться до «чи є на GitHub коміти, яких тут немає».
//
// Питаємо GitHub API, а не робимо `git fetch`: fetch переписав би
// origin/main у чужому робочому репозиторії посеред роботи, а читання з
// API нічого на диску не чіпає. Запит один — останні коміти гілки, — і
// в ньому шукаємо свій HEAD: його місце в списку і є кількість нових
// комітів. Якщо тут є ще й свої коміти, яких на GitHub немає, шукаємо
// першого спільного предка — так само, одним `git merge-base` на коміт.
//
// Без ключа GitHub дає 60 запитів на годину з однієї адреси. Тому
// перевіряємо раз на шість годин, а результат тримаємо на диску: демон
// перезапускають після кожної правки в src/, і питати щоразу заново було б
// марнотратно.
//
// Саме оновлення — scripts/update.sh: git pull і повна установка. Його
// запускаємо відірваним від демона, бо install.sh по дорозі демон
// перезапускає. Результат скрипт лишає у файлі, а прочитає його вже
// новий демон.

const fs = require('fs');
const path = require('path');
const { execFile, spawn } = require('child_process');
const config = require('./config');
const { PROJECT_DIR, DATA_DIR } = require('./paths');
const notify = require('./notify');
const { t } = require('./i18n');
const log = require('./log');

const STATUS_PATH = path.join(DATA_DIR, 'update.json');
const RESULT_PATH = path.join(DATA_DIR, 'update-result.json');
const LOG_PATH = path.join(DATA_DIR, 'update.log');
const SCRIPT = path.join(PROJECT_DIR, 'scripts', 'update.sh');

const VERSION = require('../package.json').version;

const CHECK_EVERY_MS = 6 * 60 * 60 * 1000;

// Після невдачі (немає мережі, GitHub обмежив запити) — раніше, але не
// так часто, щоб самим довбати обмеження.
const RETRY_MS = 60 * 60 * 1000;

// Такт, а не інтервал перевірки: setInterval не тікає, поки мак спить,
// тож після пробудження наступна перевірка інакше чекала б ще шість
// годин від моменту пробудження.
const TICK_MS = 15 * 60 * 1000;

// Перша перевірка — не одразу після старту: демон тільки піднявся, і
// install.sh, який його перезапустив, ще може дописувати своє.
const FIRST_TICK_MS = 30_000;

const PAGE = 50;
const SHOWN = 20;
const TIMEOUT_MS = 10_000;

// Повна установка зі збіркою програми йде хвилину-дві. Якщо за двадцять
// результату так і немає, скрипт помер так, що навіть trap не спрацював.
const INSTALL_STALE_MS = 20 * 60 * 1000;
const INSTALL_POLL_MS = 3000;

let status = load();
let inflight = null;
let installTimer = null;

function load() {
  try {
    return JSON.parse(fs.readFileSync(STATUS_PATH, 'utf8'));
  } catch {
    return { state: 'unknown', checkedAt: 0, install: { state: 'idle' } };
  }
}

function save() {
  fs.writeFile(STATUS_PATH, JSON.stringify(status, null, 2) + '\n', () => {});
}

function git(args) {
  return new Promise((resolve, reject) => {
    execFile('git', ['-C', PROJECT_DIR, ...args], { timeout: 5000 }, (err, stdout) => {
      if (err) reject(err);
      else resolve(String(stdout).trim());
    });
  });
}

const isAncestor = (sha) => git(['merge-base', '--is-ancestor', sha, 'HEAD']).then(() => true, () => false);

/** https://github.com/owner/repo(.git) або git@github.com:owner/repo(.git) → owner/repo */
function parseRepo(url) {
  const m = /github\.com[:/]([^/\s]+)\/([^/\s]+?)(?:\.git)?\/?$/.exec(url || '');
  return m ? `${m[1]}/${m[2]}` : '';
}

async function local() {
  const head = await git(['rev-parse', 'HEAD']).catch(() => '');
  if (!head) return { error: t('update.noGit') };

  const repo = parseRepo(await git(['remote', 'get-url', 'origin']).catch(() => ''));
  if (!repo) return { head, error: t('update.notGitHub') };

  // Гілка, за якою стежить поточна. Без upstream — main: так зветься
  // головна гілка самого Laserbeak.
  const upstream = await git(['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}']).catch(() => '');
  const branch = upstream.startsWith('origin/') ? upstream.slice('origin/'.length) : 'main';

  return { head, repo, branch };
}

// Помилка, текст якої вже готовий для людини.
const said = (message) => Object.assign(new Error(message), { said: true });

function describe(commit) {
  return {
    sha: commit.sha.slice(0, 7),
    message: String(commit.commit?.message || '').split('\n')[0],
    date: commit.commit?.committer?.date || commit.commit?.author?.date || '',
    url: commit.html_url || '',
  };
}

async function run({ quiet }) {
  const next = { ...status, checkedAt: Date.now(), error: '' };
  const here = await local();

  next.head = here.head || '';
  next.repo = here.repo || '';
  next.branch = here.branch || '';

  if (here.error) {
    status = { ...next, state: 'error', error: here.error, behind: 0, more: false, commits: [] };
    save();
    return status;
  }

  let list;
  try {
    const res = await fetch(
      `https://api.github.com/repos/${here.repo}/commits?sha=${encodeURIComponent(here.branch)}&per_page=${PAGE}`,
      {
        headers: { 'User-Agent': 'Laserbeak', Accept: 'application/vnd.github+json' },
        signal: AbortSignal.timeout(TIMEOUT_MS),
      },
    );

    if (res.status === 403 || res.status === 429) throw said(t('update.rateLimited'));
    if (!res.ok) throw said(t('update.network', { reason: `HTTP ${res.status}` }));
    list = await res.json();
    if (!Array.isArray(list) || !list.length) throw said(t('update.network', { reason: 'empty' }));
  } catch (err) {
    // Наші помилки вже перекладені; чужі (мережа, таймаут) загортаємо.
    const message = err.said ? err.message
      : t('update.network', { reason: err.name === 'TimeoutError' ? 'timeout' : err.message });
    log.warn(`перевірка оновлень: ${message}`);
    status = { ...next, state: 'error', error: message };
    save();
    return status;
  }

  // Де в історії GitHub стоїть ця копія. Найчастіше HEAD просто є в
  // списку; якщо ні — тут свої коміти зверху, і рахуємо від першого
  // спільного предка.
  let index = list.findIndex((c) => c.sha === here.head);
  let ahead = false;

  if (index < 0) {
    for (let i = 0; i < list.length; i += 1) {
      if (await isAncestor(list[i].sha)) { index = i; ahead = true; break; }
    }
  }

  const behind = index < 0 ? list.length : index;
  const fresh = list.slice(0, behind);

  status = {
    ...next,
    state: behind > 0 ? 'available' : (ahead ? 'ahead' : 'current'),
    behind,
    // Свого HEAD серед останніх PAGE комітів не знайшли — нового більше,
    // ніж видно.
    more: index < 0,
    latest: list[0].sha,
    commits: fresh.slice(0, SHOWN).map(describe),
  };

  // Банер — один раз на кожну нову верхівку. Перевірку з вікна
  // налаштувань людина й так бачить, тому вона банера не дає, але
  // верхівку запамʼятовує: інакше банер прилетів би згодом про те саме.
  if (status.state === 'available' && status.notified !== status.latest) {
    status.notified = status.latest;
    if (!quiet) {
      notify.announce({
        kind: 'update',
        title: t('notify.update'),
        message: status.more ? t('notify.updateSome') : t('notify.updateCount', { count: behind }),
      });
    }
  }

  log.info(`оновлення: ${status.state}${behind ? ` (+${behind}${status.more ? '+' : ''})` : ''}`);
  save();
  return status;
}

/** Перевірити зараз. Друга перевірка, поки йде перша, чекає на неї ж. */
function check({ quiet = false } = {}) {
  if (!inflight) {
    inflight = run({ quiet }).finally(() => { inflight = null; });
  }
  return inflight;
}

// ------------------------------------------------------------ установка

function installState() {
  return status.install || { state: 'idle' };
}

function setInstall(patch) {
  status = { ...status, install: { ...installState(), ...patch } };
  save();
}

/**
 * Запустити оновлення: git pull і повна установка.
 *
 * Скрипт відʼєднаний від демона (detached = setsid, своя група процесів):
 * launchd, вимикаючи демон, добиває лише його групу, а install.sh саме
 * це по дорозі й робить.
 */
function install() {
  const current = installState();
  if (current.state === 'running' && Date.now() - (current.startedAt || 0) < INSTALL_STALE_MS) {
    const busy = new Error(t('update.busy'));
    busy.code = 'EBUSY';
    throw busy;
  }

  try { fs.unlinkSync(RESULT_PATH); } catch { /* і не було */ }

  const out = fs.openSync(LOG_PATH, 'a');
  const child = spawn('/bin/bash', [SCRIPT], {
    cwd: PROJECT_DIR,
    detached: true,
    stdio: ['ignore', out, out],
    // node і npm могли прийти з nvm, а в PATH від launchd їх немає.
    env: { ...process.env, PATH: `${path.dirname(process.execPath)}:${process.env.PATH || ''}` },
  });
  child.unref();
  fs.closeSync(out);

  setInstall({
    state: 'running',
    startedAt: Date.now(),
    finishedAt: 0,
    from: status.head || '',
    to: '',
    step: '',
  });
  log.info(`оновлення запущено (pid ${child.pid}), лог: ${LOG_PATH}`);
  watchInstall();
  return installState();
}

/** Чекати, доки скрипт оновлення залишить результат. */
function watchInstall() {
  if (installTimer || installState().state !== 'running') return;

  installTimer = setInterval(() => {
    let result = null;
    try {
      result = JSON.parse(fs.readFileSync(RESULT_PATH, 'utf8'));
    } catch {
      if (Date.now() - (installState().startedAt || 0) > INSTALL_STALE_MS) {
        finishInstall({ code: -1, step: 'stale', head: '' });
      }
      return;
    }

    try { fs.unlinkSync(RESULT_PATH); } catch { /* уже прибрали */ }
    finishInstall(result);
  }, INSTALL_POLL_MS);
  installTimer.unref();
}

function finishInstall(result) {
  clearInterval(installTimer);
  installTimer = null;

  const ok = result.code === 0;
  setInstall({
    state: ok ? 'done' : 'failed',
    finishedAt: result.at ? result.at * 1000 : Date.now(),
    to: result.head || '',
    step: ok ? '' : (result.step || ''),
  });

  log.info(ok
    ? `оновлено до ${String(result.head).slice(0, 7)}`
    : `оновлення не вдалося на кроці ${result.step} (код ${result.code})`);

  notify.announce(ok
    ? { kind: 'update', title: t('notify.updated'), message: t('notify.updatedTo', { sha: String(result.head).slice(0, 7) }) }
    : { kind: 'update', title: t('notify.updateFailed'), message: t('notify.updateFailedHint') });

  // HEAD змінився — старе «доступно N змін» уже неправда.
  if (ok) check({ quiet: true }).catch(() => {});
}

// ------------------------------------------------------------ нагляд

function start() {
  const tick = async () => {
    // HEAD міг змінитись повз нас — git pull руками, свій коміт. Тоді
    // збережене «доступно» вже неправда, і перевіряти треба не чекаючи.
    const head = await git(['rev-parse', 'HEAD']).catch(() => '');
    const moved = head && head !== status.head;

    if (!config.get().updates?.check) return;
    const every = status.state === 'error' ? RETRY_MS : CHECK_EVERY_MS;
    if (!moved && Date.now() - (status.checkedAt || 0) < every) return;

    check().catch((err) => log.warn(`перевірка оновлень: ${err.message}`));
  };

  setTimeout(tick, FIRST_TICK_MS).unref();
  setInterval(tick, TICK_MS).unref();

  // Демон міг піднятись посеред оновлення — його ж і перезапустив install.sh.
  watchInstall();
}

/** Коротко — для /state: чи показати позначку «є оновлення». */
function summary() {
  return {
    state: status.state || 'unknown',
    behind: status.behind || 0,
    more: Boolean(status.more),
    checkedAt: status.checkedAt || 0,
    install: installState().state || 'idle',
  };
}

/** Повністю — для вікна налаштувань. */
function details() {
  const install = installState();
  return {
    ...summary(),
    enabled: Boolean(config.get().updates?.check),
    checking: Boolean(inflight),
    version: VERSION,
    head: (status.head || '').slice(0, 7),
    repo: status.repo || '',
    branch: status.branch || '',
    url: status.repo ? `https://github.com/${status.repo}/commits/${status.branch || 'main'}` : '',
    error: status.error || '',
    commits: status.commits || [],
    installStep: install.step || '',
    installFinishedAt: install.finishedAt || 0,
    installTo: (install.to || '').slice(0, 7),
    log: LOG_PATH,
  };
}

module.exports = { start, check, install, summary, details };
