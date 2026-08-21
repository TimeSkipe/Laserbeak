'use strict';

// Обробка подій, які приходять із хуків Claude Code.

const path = require('path');
const state = require('./state');
const { t } = require('./i18n');
const projects = require('./projects');
const sessionSettings = require('./sessionSettings');
const tokens = require('./tokens');
const roots = require('./roots');
const archive = require('./archive');
const procs = require('./procs');
const notify = require('./notify');
const log = require('./log');

/** 1 234 → "1.2k", 3 400 000 → "3.4M" */
function fmtTokens(n) {
  if (!n) return '0';
  if (n < 1000) return String(n);
  if (n < 1_000_000) return `${(n / 1000).toFixed(n < 10_000 ? 1 : 0)}k`;
  return `${(n / 1_000_000).toFixed(1)}M`;
}

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

  // Claude могли запустити в підтеці (my-app, functions...). Проєктом
  // вважається корінь, інакше кожна підтека стала б окремим проєктом.
  const projectPath = roots.resolve(cwd);
  const project = projectPath ? path.basename(projectPath) : '';

  const label = meta.label || sid.slice(0, 6);
  const base = {
    label,
    project,
    projectPath,
    cwd,
    term: meta.term || '',
    editorBundleId: meta.appBundle || '',
    // Шлях до транскрипту — джерело даних про токени.
    transcript: payload.transcript_path || '',
    // Адреса панелі tmux, якщо сесія працює через посередника.
    // Саме вона робить можливим ввід із програми й телефона.
    tmuxPane: meta.tmuxPane || '',
  };

  // Pid самого процесу claude шукаємо один раз: хук передає свій $PPID,
  // а звідти піднімаємось деревом. Це єдиний точний спосіб зрозуміти,
  // чи сесія ще жива, коли вона працює без tmux.
  const known = state.get(sid);
  if (!known?.pid && meta.hookPpid) {
    const pid = procs.nearestClaude(meta.hookPpid);
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

      // Кінець турна — момент, коли транскрипт дописаний, тож рахуємо
      // без тротлінгу і одразу знаємо, скільки зʼїв саме цей турн.
      const before = tokens.get(sid).total;
      const totals = tokens.scan(sid, base.transcript, true);
      const spent = totals.total - before;

      state.touch(sid, {
        turnStartedAt: null,
        lastTurnSeconds: elapsed,
        lastTurnTokens: spent,
        // Сумарний час роботи копиться, доки сесію не закриють остаточно.
        totalWorkSeconds: (s.totalWorkSeconds || 0) + (elapsed || 0),
      });

      const parts = [elapsed != null
        ? t('history.done', { duration: fmtDuration(elapsed) })
        : t('history.doneNoTime')];
      if (spent > 0) parts.push(t('tokens', { count: fmtTokens(spent) }));
      const message = parts.join(' · ');

      state.record({ sid, label, project, kind: 'stop', message, seconds: elapsed, tokens: spent });

      // У банері перший рядок каже, що саме сталося, другий — подробиці.
      const details = [];
      if (elapsed != null) details.push(fmtDuration(elapsed));
      if (spent > 0) details.push(t('tokens', { count: fmtTokens(spent) }));

      notify.send({
        kind: 'stop',
        sid,
        appBundle: base.editorBundleId,
        project,
        cwd: projectPath,
        term: base.term,
        title: `✅ ${project || 'Claude Code'}`,
        subtitle: sessionSettings.displayName(sid, label),
        message: [t('notify.done'), details.join(' · ')].filter(Boolean).join('\n'),
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
    case 'notification':
    case 'permission': {
      const raw = payload.message || '';
      const needsApproval = /permission|approval|approve|дозвол|схвал/i.test(raw);

      if (needsApproval) {
        state.touch(sid, { ...base, status: 'needs-input' });
        state.record({ sid, label, project, kind: 'permission', message: raw });

        notify.send({
          kind: 'permission',
          sid,
          appBundle: base.editorBundleId,
          project,
          cwd: projectPath,
          term: base.term,
          title: `⏸ ${project || 'Claude Code'}`,
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
      state.record({ sid, label, project, kind: 'idle', message: raw || 'чекає на ввід' });

      notify.send({
        kind: 'idle',
        sid,
        appBundle: base.editorBundleId,
        project,
        cwd: projectPath,
        term: base.term,
        title: `⌛ ${project || 'Claude Code'}`,
        subtitle: sessionSettings.displayName(sid, label),
        message: t('notify.idle'),
      });
      break;
    }

    case 'session-end':
      tokens.forget(sid);
      state.remove(sid);
      state.record({ sid, label, project, kind: 'session-end', message: t('history.closed') });
      break;

    default:
      log.warn(`невідома подія хука: ${event}`);
  }
}

module.exports = { handle, fmtDuration, fmtTokens };
