'use strict';

// Обробка подій, які приходять із хуків Claude Code і Codex.
//
// Хуки в них майже однакові (SessionStart, UserPromptSubmit, Stop,
// SessionEnd), тож і шлях один. Відмінності три, і всі тут:
//   • запит дозволу — в обох PermissionRequest (у нас approval), а в
//     Claude ще й Notification, який розпізнаємо за полем
//     notification_type (запасний шлях — текст);
//   • переривання (Esc посеред ходу) Codex повідомляє окремо — без цього
//     сесія лишалась би «працює» до наступного запиту;
//   • транскрипт Codex — зовсім інший формат, тож архів, який уміє
//     читати лише Claude, його не отримує.

const path = require('path');
const state = require('./state');
const { t } = require('./i18n');
const projects = require('./projects');
const sessionSettings = require('./sessionSettings');
const roots = require('./roots');
const archive = require('./archive');
const rollout = require('./rollout');
const procs = require('./procs');
const notify = require('./notify');
const log = require('./log');

// Значення notification_type у Claude Code 2.1.306 (перевірено в бінарнику).
// worker_permission_prompt — дозвіл для субагента або воркера.
const PERMISSION_TYPES = new Set(['permission_prompt', 'worker_permission_prompt']);
const IDLE_TYPES = new Set(['idle_prompt']);

function fmtDuration(sec) {
  if (sec == null || !isFinite(sec)) return '';
  if (sec < 60) return t('dur.seconds', { s: Math.round(sec) });
  const m = Math.floor(sec / 60);
  const s = Math.round(sec % 60);
  if (m < 60) return t('dur.minutes', { m, s });
  return t('dur.hours', { h: Math.floor(m / 60), m: m % 60 });
}

/**
 * @param {string} event   назва події з URL хука
 * @param {object} payload JSON, який Claude Code передав хуку
 * @param {{label:string, term:string, appBundle:string}} meta заголовки від hook.sh
 */
function handle(event, payload, meta) {
  const sid = payload.session_id || 'unknown';
  const cwd = payload.cwd || '';
  const agent = meta.agent === 'codex' ? 'codex' : 'claude';
  const product = agent === 'codex' ? 'Codex' : 'Claude Code';

  // Claude могли запустити в підтеці (my-app, functions...). Проєктом
  // вважається корінь, інакше кожна підтека стала б окремим проєктом.
  const projectPath = roots.resolve(cwd);
  const project = projectPath ? path.basename(projectPath) : '';

  const label = meta.label || sid.slice(0, 6);
  const base = {
    agent,
    label,
    project,
    projectPath,
    cwd,
    term: meta.term || '',
    editorBundleId: meta.appBundle || '',
    // Шлях до транскрипту — джерело даних про токени й архіву. Лише для
    // Claude: rollout-файл Codex — інший формат, і тутешні читачі
    // побачили б у ньому нулі або сміття.
    transcript: agent === 'claude' ? payload.transcript_path || '' : '',
    // Адреса панелі tmux, якщо сесія працює через посередника.
    // Саме вона робить можливим ввід ззовні: скріншоти з браузера,
    // перемикання режиму, команди.
    tmuxPane: meta.tmuxPane || '',
  };

  // Pid самого процесу агента шукаємо один раз: хук передає свій $PPID,
  // а звідти піднімаємось деревом. Це єдиний точний спосіб зрозуміти,
  // чи сесія ще жива, коли вона працює без tmux.
  const known = state.get(sid);
  if (!known?.pid && meta.hookPpid) {
    const pid = procs.nearestAgent(meta.hookPpid);
    if (pid) base.pid = pid;
  }

  // Будь-яка активність оновлює реєстр проєктів — він переживає
  // перезапуск демона, тому список проєктів не зникає разом із сесіями.
  if (projectPath) projects.touch(projectPath, meta.appBundle);

  // Переписку забираємо на кожній події: транскрипт Claude Code живе
  // лише 30 днів, а читання інкрементне, тож коштує майже нічого.
  if (base.transcript) {
    archive.ingest(sid, base.transcript, { label, project, projectPath });
  }

  switch (event) {
    case 'session-start':
      state.touch(sid, { ...base, status: 'idle', since: Date.now() });
      state.record({ sid, label, project, kind: 'session-start', message: t('history.opened') });
      break;

    case 'prompt': {
      const prev = state.get(sid);
      state.touch(sid, {
        ...base,
        status: 'working',
        turnStartedAt: Date.now(),
        turns: (prev?.turns || 0) + 1,
      });
      break;
    }

    case 'stop': {
      const s = state.touch(sid, { ...base, status: 'waiting' });
      const elapsed = s.turnStartedAt ? (Date.now() - s.turnStartedAt) / 1000 : null;

      state.touch(sid, {
        turnStartedAt: null,
        lastTurnSeconds: elapsed,
        // Сумарний час роботи копиться, доки сесію не закриють остаточно.
        totalWorkSeconds: (s.totalWorkSeconds || 0) + (elapsed || 0),
      });

      const message = elapsed != null
        ? t('history.done', { duration: fmtDuration(elapsed) })
        : t('history.doneNoTime');

      state.record({ sid, label, project, kind: 'stop', message, seconds: elapsed });

      notify.send({
        kind: 'stop',
        sid,
        appBundle: base.editorBundleId,
        project,
        cwd: projectPath,
        term: base.term,
        title: `✅ ${project || product}`,
        subtitle: sessionSettings.displayName(sid, label),
        // Перший рядок — що сталося, другий — скільки тривало.
        message: [t('notify.done'), elapsed != null ? fmtDuration(elapsed) : ''].filter(Boolean).join('\n'),
      });
      break;
    }

    // Хук Notification у Claude Code спрацьовує на дві різні речі:
    //
    //   "Claude needs your permission…"  — справжній запит дозволу
    //   "Claude is waiting for your input" — просто нагадування, що
    //                                        сесія чекає на твій ввід
    //
    // Це не одне й те саме: друге прилітає через хвилину після звичайного
    // завершення відповіді. Якщо не розрізняти, сесія помилково виглядає
    // так, ніби Claude щось питає.
    //
    // Codex тексту не шле зовсім: його PermissionRequest (у нас approval)
    // уже сам по собі означає «потрібен дозвіл», а в даних — лише назва
    // інструмента, якому він потрібен.
    //
    // Розрізняємо передусім за полем notification_type, а не за текстом:
    // текст англійський і може змінитись (у Claude Code 2.1 він уже лежить
    // у таблиці рядків інтерфейсу). Поле обов'язкове в схемі хука, значення
    // перевірено в бінарнику 2.1.306. Невідомий тип або його відсутність
    // (старіші версії, схвалення плану, яке йде через діалог) — як раніше,
    // за текстом.
    case 'notification':
    case 'permission':
    case 'approval': {
      const raw = payload.message || '';
      const type = String(payload.notification_type || '');
      const needsApproval = event === 'approval'
        || PERMISSION_TYPES.has(type)
        || (!IDLE_TYPES.has(type) && /permission|approval|approve|дозвол|схвал/i.test(raw));

      // Про один запит Claude Code каже двічі: PermissionRequest — щойно
      // зʼявився діалог, а Notification — через шість секунд (виміряно на
      // 24 запитах), якщо відповіді досі немає. Друге — повтор: тривогу й
      // банер уже показано.
      if (needsApproval && event !== 'approval'
          && known?.status === 'needs-input' && known.needsInputVia === 'request') {
        break;
      }

      if (needsApproval) {
        // В історію — перекладений текст: від Claude Code приходить
        // англійською, а людина вибрала свою мову. Оригінал лишається
        // в events.jsonl полем detail.
        const why = [t('notify.permission'), payload.tool_name].filter(Boolean).join(': ');
        // Коли почала чекати: продовження після відповіді демон побачить у
        // транскрипті (daemon.js) — агент сам до кінця ходу не скаже. У
        // Codex транскрипт — rollout-файл, читаємо лише дописане після
        // запиту.
        if (agent === 'codex') rollout.mark(sid, payload.transcript_path);
        state.touch(sid, {
          ...base,
          status: 'needs-input',
          needsInputAt: Date.now(),
          needsInputVia: event === 'approval' ? 'request' : 'notification',
        });
        state.record({ sid, label, project, kind: 'permission', message: why, detail: raw });

        notify.send({
          kind: 'permission',
          sid,
          appBundle: base.editorBundleId,
          project,
          cwd: projectPath,
          term: base.term,
          title: `⏸ ${project || product}`,
          subtitle: sessionSettings.displayName(sid, label),
          // Причину в банер не пишемо — важливий сам факт, що чекають
          // на тебе. Повний текст лишається в історії.
          message: t('notify.permission'),
        });
        break;
      }

      // Сесія просто чекає на тебе. Статус лишається «закінчила», бо
      // роботу вона завершила — нічого не питає.
      state.touch(sid, { ...base, status: 'waiting' });
      state.record({ sid, label, project, kind: 'idle', message: t('history.waiting'), detail: raw });

      notify.send({
        kind: 'idle',
        sid,
        appBundle: base.editorBundleId,
        project,
        cwd: projectPath,
        term: base.term,
        title: `⌛ ${project || product}`,
        subtitle: sessionSettings.displayName(sid, label),
        message: t('notify.idle'),
      });
      break;
    }

    // Codex: хід перервали (Esc). Stop тоді може й не прийти, а без цього
    // сесія висіла б «працює» до наступного запиту. Сповіщення не треба —
    // перервала сама людина, і вона про це знає.
    case 'interrupt': {
      const s = state.touch(sid, { ...base, status: 'waiting' });
      const elapsed = s.turnStartedAt ? (Date.now() - s.turnStartedAt) / 1000 : null;
      state.touch(sid, {
        turnStartedAt: null,
        lastTurnSeconds: elapsed,
        totalWorkSeconds: (s.totalWorkSeconds || 0) + (elapsed || 0),
      });
      break;
    }

    case 'session-end':
      state.remove(sid);
      rollout.forget(sid);
      state.record({ sid, label, project, kind: 'session-end', message: t('history.closed') });
      break;

    default:
      log.warn(`невідома подія хука: ${event}`);
  }
}

module.exports = { handle, fmtDuration };
