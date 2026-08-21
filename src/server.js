'use strict';

// HTTP API демона.
//
//   POST /hook/<event>   ← hook.sh із сесії Claude Code (тільки з localhost)
//   GET  /state          → знімок для застосунків на маку й телефоні
//   GET  /health         → пінг
//
// Слухає bindHost із конфігу. За замовчуванням 0.0.0.0, щоб телефон
// у тій же Wi-Fi бачив демон.
//
// Три рівні доступу:
//
//   лише localhost   події хуків і запуск процесів — те, що пише в стан
//                    або створює щось нове на компʼютері;
//   ключ             усе інше, що приходить із мережі;
//   без обмежень     нічого.
//
// Запити з 127.0.0.1 ключа не потребують: там і так може писати лише
// той, хто вже сидить за цим компʼютером.

const http = require('http');
const auth = require('./auth');
const state = require('./state');
const events = require('./events');
const projects = require('./projects');
const sessionSettings = require('./sessionSettings');
const outbox = require('./outbox');
const archive = require('./archive');
const terminals = require('./terminals');
const tmux = require('./tmux');
const modes = require('./modes');
const input = require('./input');
const shots = require('./shots');
const config = require('./config');
const { t } = require('./i18n');
const reaper = require('./reaper');
const inspect = require('./inspect');
const notify = require('./notify');
const log = require('./log');

const MAX_BODY = 2 * 1024 * 1024;

// Скріншот зони приходить як base64, а це +33% до розміру картинки.
// Розширення й так тисне її перед відправкою, але межу треба тримати
// вищу за звичайну, інакше великий знімок мовчки обірветься.
const MAX_SHOT_BODY = 8 * 1024 * 1024;

// Скільки тримати відкритим запит на сповіщення. Коротше за вікно,
// протягом якого демон вважає програму живою.
const WAIT_TIMEOUT_MS = 20_000;

// Node віддає заголовки як latin-1, тож кирилична мітка (start "проба")
// приїхала б кракозябрами. Повертаємо байти назад у UTF-8.
function headerUtf8(value) {
  return value ? Buffer.from(String(value), 'latin1').toString('utf8') : '';
}

function json(res, code, body) {
  const buf = Buffer.from(JSON.stringify(body));
  const headers = {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': buf.length,
    'Cache-Control': 'no-store',
  };

  // Розширення читає відповідь із попапа, а не лише з service worker,
  // тому дозвіл треба віддати явно. Адреса тут конкретна — не «*»:
  // її вже перевірив originAllowed, і повторювати дозвіл ширше нема за що.
  if (res._extensionOrigin) {
    headers['Access-Control-Allow-Origin'] = res._extensionOrigin;
    headers['Vary'] = 'Origin';
  }

  res.writeHead(code, headers);
  res.end(buf);
}

function readBody(req, limit = MAX_BODY) {
  return new Promise((resolve) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) { req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', () => resolve(''));
  });
}

function isLocal(req) {
  const a = req.socket.remoteAddress || '';
  return a === '127.0.0.1' || a === '::1' || a === '::ffff:127.0.0.1';
}

// Localhost = довіра, і доти, доки в неї ходили лише наші програми, це
// було чесно. Браузер міняє умову: чужий код там опиняється сам, варто
// відкрити вкладку.
//
// Прочитати відповідь стороння сторінка не зможе — ми не віддаємо
// Access-Control-Allow-Origin, і браузер їй не покаже. Але POST із
// простим Content-Type летить без preflight, тобто **дія виконається**,
// хоч відповіді ніхто й не побачить. Для /sessions/spawn навіть sid не
// потрібен — досить угадати шлях до проєкту.
//
// Тому дивимось на Origin. Підробити його зі сторінки не можна, це
// робить сам браузер:
//
//   немає             свої клієнти (Swift, curl, hook.sh) — пускаємо
//   chrome-extension  наше розширення — пускаємо
//   http(s)           сторінка з мережі — не пускаємо ніколи
function originAllowed(req) {
  const origin = req.headers.origin;
  if (!origin) return true;

  const allowed = config.get().extensionId;
  if (allowed) return origin === `chrome-extension://${allowed}`;

  return origin.startsWith('chrome-extension://');
}

// Скільки скарг на невірний ключ писати в лог з однієї адреси, перш ніж
// замовкнути. Без цього чужий скрипт, який довбиться раз на секунду,
// за ніч роздує лог до гігабайтів.
const COMPLAINTS_PER_HOST = 3;

// І скільки адрес узагалі памʼятати: сканер, що ходить із сотень адрес,
// інакше поволі роздував би цю мапу.
const COMPLAINT_HOSTS = 200;

const complaints = new Map();

function complainOnce(address, path) {
  const count = complaints.get(address) || 0;
  if (count >= COMPLAINTS_PER_HOST) return;

  if (!complaints.has(address) && complaints.size >= COMPLAINT_HOSTS) {
    // Забуваємо найдавнішу: Map зберігає порядок додавання.
    complaints.delete(complaints.keys().next().value);
  }

  complaints.set(address, count + 1);
  log.warn(`відмовлено ${address} → ${path}: невірний ключ доступу`
    + (count + 1 === COMPLAINTS_PER_HOST ? ' (далі мовчу про цю адресу)' : ''));
}

// Дозволені команди й значення. Список тут, а не в програмі: демон —
// єдине джерело істини, і телефон не має вигадувати назви.
const MODELS = ['default', 'opus', 'fable', 'sonnet', 'haiku'];

function buildCommand(body) {
  if (!body || !body.sid) return '';

  if (body.model) {
    return MODELS.includes(body.model) ? `/model ${body.model}` : '';
  }

  if (body.effort) {
    return modes.EFFORT_LEVELS.includes(body.effort) ? `/effort ${body.effort}` : '';
  }

  if (body.compact) return '/compact';

  return '';
}

function createServer() {
  return http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    const p = url.pathname;

    // Сторінка з мережі не має говорити з демоном навіть із localhost.
    if (!originAllowed(req)) {
      return json(res, 403, { ok: false, error: t('err.badOrigin') });
    }

    // Запам'ятовуємо для json(): відповідь розширенню треба явно дозволити
    // прочитати, інакше браузер сховає її від попапа.
    const origin = req.headers.origin;
    if (origin && origin.startsWith('chrome-extension://')) {
      res._extensionOrigin = origin;
    }

    // Preflight на POST із JSON. Розширення робить його не завжди, але
    // коли робить — відповідь має прийти без тіла й без роздумів.
    if (req.method === 'OPTIONS') {
      res.writeHead(204, {
        'Access-Control-Allow-Origin': res._extensionOrigin || 'null',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization',
        'Access-Control-Max-Age': '86400',
        'Vary': 'Origin',
      });
      return res.end();
    }

    // Усе, що прийшло з мережі, має принести ключ. Виняток лише для
    // хуків і /sessions/spawn — вони й так дозволені тільки з localhost
    // і відмовляють нижче самі.
    if (!isLocal(req) && !auth.isAuthorized(req)) {
      complainOnce(req.socket.remoteAddress || '?', p);
      return json(res, 401, {
        ok: false,
        error: t('err.needToken'),
      });
    }

    // Події приймаємо лише з цього комп'ютера — писати в стан ззовні
    // не має права ніхто, навіть у своїй мережі.
    if (req.method === 'POST' && p.startsWith('/hook/')) {
      if (!isLocal(req)) return json(res, 403, { ok: false });

      const raw = await readBody(req);
      json(res, 200, { ok: true });   // відповідаємо одразу, сесія не чекає

      let payload = {};
      try { payload = raw ? JSON.parse(raw) : {}; } catch { payload = {}; }

      try {
        events.handle(p.slice('/hook/'.length), payload, {
          label: headerUtf8(req.headers['x-claude-label']),
          term: headerUtf8(req.headers['x-term-program']),
          appBundle: headerUtf8(req.headers['x-app-bundle']),
          tmuxPane: headerUtf8(req.headers['x-tmux-pane']),
          hookPpid: headerUtf8(req.headers['x-hook-ppid']),
        });
      } catch (e) {
        log.error(`handle: ${e.stack || e}`);
      }
      return;
    }

    // Примусове оновлення на вимогу — кнопка «Оновити» в програмі.
    //
    // Демон і так перевіряє живучість сесій щопівхвилини, а процеси
    // переглядає раз на кілька секунд. Але коли ти щойно закрив вкладку
    // й дивишся у вікно, чекати не хочеться. Тут усе робиться негайно:
    // огляд процесів, перевірка сесій, дочитування переписки й скидання
    // кешу режимів.
    if (req.method === 'POST' && p === '/refresh') {
      await inspect.refresh();
      const removed = reaper.reap();
      modes.clear();

      try {
        archive.ingestRecent();
      } catch { /* архів не критичний для оновлення */ }

      if (removed.length) {
        log.info(`оновлення на вимогу: прибрано сесій ${removed.length}`);
      }

      return json(res, 200, {
        ok: true,
        removed,
        ...state.snapshot(),
        notifierInstalled: notify.isNotifierInstalled(),
      });
    }

    if (req.method === 'GET' && p === '/state') {
      return json(res, 200, {
        ok: true,
        ...state.snapshot(),
        notifierInstalled: notify.isNotifierInstalled(),
      });
    }

    // Налаштування проєкту — це користувацькі вподобання, тому їх можна
    // міняти і з телефона. Події хуків, на відміну від цього, приймаються
    // лише з цього комп'ютера.
    if (req.method === 'POST' && p === '/projects/settings') {
      const raw = await readBody(req);
      let body = {};
      try { body = JSON.parse(raw); } catch { return json(res, 400, { ok: false, error: 'bad json' }); }

      if (!body.path) return json(res, 400, { ok: false, error: 'path обовʼязковий' });

      const updated = projects.updateSettings(body.path, body.settings);
      if (!updated) return json(res, 404, { ok: false, error: t('err.noProject') });

      log.info(`налаштування проєкту ${updated.name} оновлено`);
      return json(res, 200, { ok: true, project: updated });
    }

    // Своя назва сесії та вимикач її сповіщень.
    if (req.method === 'POST' && p === '/sessions/settings') {
      const raw = await readBody(req);
      let body = {};
      try { body = JSON.parse(raw); } catch { return json(res, 400, { ok: false, error: 'bad json' }); }

      if (!body.sid) return json(res, 400, { ok: false, error: 'sid обовʼязковий' });

      const patch = {};
      if ('alias' in body) patch.alias = body.alias;
      if ('notify' in body) patch.notify = body.notify;

      const saved = sessionSettings.update(body.sid, patch);
      log.info(`сесія ${body.sid.slice(0, 8)}: ${JSON.stringify(saved)}`);
      return json(res, 200, { ok: true, settings: saved });
    }

    if (req.method === 'POST' && p === '/projects/forget') {
      const raw = await readBody(req);
      let body = {};
      try { body = JSON.parse(raw); } catch { return json(res, 400, { ok: false, error: 'bad json' }); }

      const removed = projects.forget(body.path);
      return json(res, removed ? 200 : 404, { ok: removed });
    }

    // Довге очікування сповіщень для програми на маку.
    //
    // Запит висить відкритим до появи події або до таймауту. Так банер
    // з'являється миттєво, а не з затримкою опитування, і при цьому
    // мережею майже нічого не ходить.
    if (req.method === 'GET' && p === '/events/wait') {
      const asked = Number(url.searchParams.get('since') || 0);
      const current = outbox.currentSeq();

      // asked = 0 означає, що клієнт щойно запустився і не знає, де він.
      // Починаємо з поточного моменту, щоб не сипати накопиченим.
      //
      // asked > current означає, що демон перезапустили і лічильник почався
      // з нуля. Тоді віддаємо все, що вже встигло накопичитись, — інакше
      // перша ж подія після перезапуску губилася б.
      const from = asked <= 0 ? current : Math.min(asked, current);

      let closed = false;
      req.on('close', () => { closed = true; });

      const notifications = await outbox.wait(from, WAIT_TIMEOUT_MS);
      if (closed) return;

      return json(res, 200, {
        ok: true,
        seq: outbox.currentSeq(),
        notifications,
      });
    }

    // Запустити нову сесію Claude Code у власному терміналі демона.
    // Лише з цього компʼютера: це запуск процесу, не налаштування.
    if (req.method === 'POST' && p === '/sessions/spawn') {
      if (!isLocal(req)) return json(res, 403, { ok: false });

      const raw = await readBody(req);
      let body = {};
      try { body = JSON.parse(raw); } catch { return json(res, 400, { ok: false, error: 'bad json' }); }

      if (!body.projectPath) return json(res, 400, { ok: false, error: 'projectPath обовʼязковий' });

      try {
        const entry = terminals.start({
          projectPath: body.projectPath,
          label: body.label || '',
          prompt: body.prompt || '',
        });
        return json(res, 200, { ok: true, sid: entry.sid, label: entry.label });
      } catch (err) {
        return json(res, 400, { ok: false, error: err.message });
      }
    }

    // Написати в сесію так, ніби текст набрали з клавіатури.
    if (req.method === 'POST' && p === '/sessions/input') {
      const raw = await readBody(req);
      let body = {};
      try { body = JSON.parse(raw); } catch { return json(res, 400, { ok: false, error: 'bad json' }); }

      if (!body.sid || !body.text) {
        return json(res, 400, { ok: false, error: t('err.needSidText') });
      }

      const short = body.sid.slice(0, 8);
      const preview = String(body.text).slice(0, 60);

      try {
        const { via } = input.send(body.sid, body.text);
        log.info(`ввід у сесію ${short} (${via}): ${preview}`);
        return json(res, 200, { ok: true, via });
      } catch (err) {
        return json(res, 409, { ok: false, error: err.message });
      }
    }

    // Скріншот зони зі сторінки в браузері.
    //
    // Ввід у сесію текстовий, тож картинка лягає у файл, а в сесію йде
    // рядок зі шляхом — Claude Code відкриє її власним Read. Тобто це
    // звичайний ввід, просто зібраний за нас: input.js про скріншоти не
    // знає й не мусить.
    //
    // Маршрут окремий від /sessions/input саме тому, що збирає текст
    // демон: у розширення немає своєї думки про те, як розмовляти з
    // сесією, і не має бути — воно надсилає зону, адресу й коментар.
    if (req.method === 'POST' && p === '/sessions/shot') {
      const raw = await readBody(req, MAX_SHOT_BODY);
      let body = {};
      try { body = JSON.parse(raw); } catch { return json(res, 400, { ok: false, error: 'bad json' }); }

      if (!body.sid || !body.image) {
        return json(res, 400, { ok: false, error: t('err.needSidImage') });
      }

      if (!state.get(body.sid) && !terminals.isHosted(body.sid)) {
        return json(res, 404, { ok: false, error: t('err.noSession') });
      }

      // Перевіряємо шлях у сесію до того, як писати файл: інакше на диску
      // лишався б смітник щоразу, коли сесію запущено без посередника.
      if (!input.canSend(body.sid)) {
        return json(res, 409, {
          ok: false,
          error: t('err.noWayIn'),
        });
      }

      let saved;
      try {
        saved = shots.save({ sid: body.sid, image: body.image });
      } catch (err) {
        return json(res, 400, { ok: false, error: err.message });
      }

      const text = shots.prompt({
        file: saved.file,
        comment: body.comment,
        url: body.url,
        selector: body.selector,
        text: body.text,
        size: body.size,
      });

      try {
        const { via } = input.send(body.sid, text);
        const kb = Math.round(saved.bytes / 1024);
        log.info(`скрін зони → сесія ${body.sid.slice(0, 8)} (${via}, ${kb} КБ):`
          + ` ${String(body.comment || '').slice(0, 60)}`);
        return json(res, 200, { ok: true, via, file: saved.file, bytes: saved.bytes });
      } catch (err) {
        return json(res, 409, { ok: false, error: err.message });
      }
    }

    // Слеш-команди Claude Code: модель, рівень зусиль, стиснення.
    //
    // Технічно це той самий ввід у сесію, але маршрути окремі й зі
    // списком дозволеного: програма має показувати справжні варіанти,
    // а не давати телефону слати в сесію будь-який рядок як команду.
    if (req.method === 'POST' && p === '/sessions/command') {
      const raw = await readBody(req);
      let body = {};
      try { body = JSON.parse(raw); } catch { return json(res, 400, { ok: false, error: 'bad json' }); }

      const command = buildCommand(body);
      if (!command) {
        return json(res, 400, { ok: false, error: t('err.badCommand') });
      }

      if (!state.get(body.sid) && !terminals.isHosted(body.sid)) {
        return json(res, 404, { ok: false, error: t('err.noSession') });
      }

      try {
        const { via } = input.send(body.sid, command);
        log.info(`команда ${command} → сесія ${body.sid.slice(0, 8)} (${via})`);

        // Модель і зусилля змінюють те, що намальовано у смужці, а її ми
        // кешуємо на три секунди. Скидаємо, щоб програма побачила нове
        // одразу, а не через такт.
        modes.forget(body.sid);

        return json(res, 200, { ok: true, via, command });
      } catch (err) {
        return json(res, 409, { ok: false, error: err.message });
      }
    }

    if (req.method === 'POST' && p === '/sessions/interrupt') {
      const raw = await readBody(req);
      let body = {};
      try { body = JSON.parse(raw); } catch { return json(res, 400, { ok: false, error: 'bad json' }); }

      if (terminals.isHosted(body.sid)) {
        return json(res, 200, { ok: terminals.interrupt(body.sid) });
      }

      const target = state.get(body.sid);
      return json(res, 200, { ok: target?.tmuxPane ? tmux.interrupt(target.tmuxPane) : false });
    }

    // Перемкнути режим дозволів сесії.
    //
    // Порядок кола Shift+Tab ніде не зафіксований, тому ми його не
    // припускаємо: тиснемо і перечитуємо транскрипт, доки не отримаємо
    // потрібний режим.
    if (req.method === 'POST' && p === '/sessions/mode') {
      const raw = await readBody(req);
      let body = {};
      try { body = JSON.parse(raw); } catch { return json(res, 400, { ok: false, error: 'bad json' }); }

      const session = state.get(body.sid);
      if (!session) return json(res, 404, { ok: false, error: t('err.noSession') });

      const press = terminals.isHosted(body.sid)
        ? () => terminals.shiftTab(body.sid)
        : (session.tmuxPane ? () => tmux.shiftTab(session.tmuxPane) : null);

      if (!press) {
        return json(res, 409, {
          ok: false,
          error: t('err.noWayIn'),
        });
      }

      try {
        const result = await modes.switchTo({
          session,
          target: body.mode,
          press,
        });
        return json(res, result.ok ? 200 : 409, { ok: result.ok, ...result });
      } catch (err) {
        return json(res, 400, { ok: false, error: err.message });
      }
    }

    // Прибрати сесію зі списку вручну.
    //
    // Автоматичні перевірки не всесильні: якщо в проєкті кілька сесій
    // без tmux, демон не знає, який процес чий, і не може сказати, яку
    // саме ти закрив. Тому лишається спосіб прибрати руками.
    if (req.method === 'POST' && p === '/sessions/forget') {
      const raw = await readBody(req);
      let body = {};
      try { body = JSON.parse(raw); } catch { return json(res, 400, { ok: false, error: 'bad json' }); }

      const session = state.get(body.sid);
      if (!session) return json(res, 404, { ok: false, error: t('err.noSession') });

      state.remove(body.sid);
      modes.forget(body.sid);
      state.record({
        sid: body.sid,
        label: session.label,
        project: session.project,
        kind: 'session-end',
        message: 'прибрано вручну',
      });

      log.info(`сесію ${session.label} прибрано вручну`);
      return json(res, 200, { ok: true });
    }

    if (req.method === 'POST' && p === '/sessions/stop') {
      const raw = await readBody(req);
      let body = {};
      try { body = JSON.parse(raw); } catch { return json(res, 400, { ok: false, error: 'bad json' }); }

      return json(res, 200, { ok: terminals.stop(body.sid) });
    }

    // Сирий вивід термінала — для розбору проблем.
    if (req.method === 'GET' && p.startsWith('/sessions/output/')) {
      const sid = decodeURIComponent(p.slice('/sessions/output/'.length));
      return json(res, 200, { ok: true, output: terminals.output(sid) });
    }

    // Список сесій, переписку яких збережено.
    if (req.method === 'GET' && p === '/archive') {
      return json(res, 200, { ok: true, sessions: archive.list() });
    }

    // Сама переписка: /archive/<sid>?limit=200
    if (req.method === 'GET' && p.startsWith('/archive/')) {
      const sid = decodeURIComponent(p.slice('/archive/'.length));
      const meta = archive.meta(sid);
      if (!meta) return json(res, 404, { ok: false, error: t('err.noSessionInArchive') });

      return json(res, 200, {
        ok: true,
        session: meta,
        messages: archive.read(sid, {
          limit: Number(url.searchParams.get('limit') || 0),
          includeSidechain: url.searchParams.get('subagents') === '1',
        }),
      });
    }

    // Ключ доступу. Лише з localhost: його показує програма на маку —
    // у QR-коді й як пароль зашифрованого зʼєднання з телефоном.
    if (req.method === 'GET' && p === '/auth/token') {
      if (!isLocal(req)) return json(res, 403, { ok: false });
      return json(res, 200, { ok: true, token: auth.get() });
    }

    // Новий ключ: старі телефони відпадуть, доки не відсканують код знову.
    if (req.method === 'POST' && p === '/auth/rotate') {
      if (!isLocal(req)) return json(res, 403, { ok: false });
      complaints.clear();
      return json(res, 200, { ok: true, token: auth.rotate() });
    }

    if (p === '/health') {
      return json(res, 200, { ok: true, pid: process.pid, outbox: outbox.stats() });
    }

    json(res, 404, { ok: false, error: 'not found' });
  });
}

module.exports = { createServer };
