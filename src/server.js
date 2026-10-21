'use strict';

// HTTP API демона.
//
//   POST /hook/<event>   ← hook.sh із сесії Claude Code
//   GET  /state          → знімок для програми на маку й розширення
//   GET  /health         → пінг
//
// Слухає лише 127.0.0.1 (див. daemon.js): клієнтів поза цим компʼютером
// у демона немає. Тож доступ вирішують дві перевірки на вході, обидві
// тут, в одному місці:
//
//   адреса   не 127.0.0.1 — 403. Сюди й так нічого не долетить, але
//            одна стрічка коштує менше, ніж віра в те, що bind ніхто
//            ніколи не поміняє;
//   Origin   сторінка з мережі — 403, навіть із localhost (див. нижче).
//
// Новий маршрут нічого робити не мусить — обидві перевірки вже стоять.

const http = require('http');
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
const settings = require('./settings');
const updates = require('./updates');
const { t, tLog } = require('./i18n');
const reaper = require('./reaper');
const inspect = require('./inspect');
const notify = require('./notify');
const log = require('./log');

const MAX_BODY = 2 * 1024 * 1024;

// Скріншот зони приходить як base64, а це +33% до розміру картинки.
// Розширення й так тисне її перед відправкою, але межу треба тримати
// вищу за звичайну, інакше великий знімок мовчки обірветься. Послідовність
// знімків їде одним запитом; розширення тримає її в storage.session, а
// там стеля 10 МБ — тож більше, ніж 16, сюди прийти не може.
const MAX_SHOT_BODY = 16 * 1024 * 1024;

// Скільки тримати відкритим запит на сповіщення. Коротше за вікно,
// протягом якого демон вважає програму живою.
const WAIT_TIMEOUT_MS = 20_000;

// Node віддає заголовки як latin-1, тож кирилична мітка (start "проба")
// приїхала б кракозябрами. Повертаємо байти назад у UTF-8.
function headerUtf8(value) {
  return value ? Buffer.from(String(value), 'latin1').toString('utf8') : '';
}

function json(res, code, body) {
  // Відмову клієнт покаже людині, але без цього рядка в лозі не лишилось
  // би сліду, що, де й чому не вийшло. 500 уже записано разом зі стеком.
  if (code >= 400 && code !== 500 && !res._logged) {
    const route = res._route || '?';
    const why = res._logText || body?.error || body?.reason || '';
    const from = res._refused ? ` (Origin ${res._refused})` : '';
    log.warnRepeated(`${route} ${code} ${why}${from}`, `${route} → ${code}${why ? `: ${why}` : ''}${from}`);
  }

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

// Відмова: клієнту — вибраною мовою, у лог — українською, як решта лога.
function fail(res, code, key, params) {
  res._logText = tLog(key, params);
  return json(res, code, { ok: false, error: t(key, params) });
}

// Помилка, що вилетіла з коду. Своя (`said`) уже перекладена — віддаємо
// як є. Чужа (ENOSPC, EPIPE, збій tmux) людині нічого не скаже, та ще й
// англійською: клієнту — «внутрішня помилка», у errors.log — сира причина.
function failErr(res, code, err) {
  if (err?.said) {
    res._logText = err.logText;
    return json(res, code, { ok: false, error: err.message });
  }
  log.error(`${res._route || '?'} → ${code}`, err);
  res._logged = true;
  return json(res, code, { ok: false, error: t('err.internal') });
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

// Дозволені команди й значення. Список тут, а не в програмі: демон —
// єдине джерело істини, і клієнт не має вигадувати назви.
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

async function handle(req, res) {
  const url = new URL(req.url, 'http://127.0.0.1');
  const p = url.pathname;
  res._route = `${req.method} ${p}`;

  // Сторінка з мережі не має говорити з демоном навіть із localhost.
  // Хто саме стукав — у лог: це єдиний слід спроби зі сторінки.
  if (!originAllowed(req)) {
    res._refused = String(req.headers.origin).slice(0, 120);
    return fail(res, 403, 'err.badOrigin');
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
      'Access-Control-Allow-Headers': 'Content-Type',
      'Access-Control-Max-Age': '86400',
      'Vary': 'Origin',
    });
    return res.end();
  }

  // Лише з цього компʼютера. Демон і слухає тільки 127.0.0.1, тож це
  // запобіжник на випадок, якщо адресу колись поміняють.
  if (!isLocal(req)) {
    return fail(res, 403, 'err.onlyLocal');
  }

  if (req.method === 'POST' && p.startsWith('/hook/')) {
    const raw = await readBody(req);
    json(res, 200, { ok: true });   // відповідаємо одразу, сесія не чекає

    const event = p.slice('/hook/'.length);
    let payload = {};
    try {
      payload = raw ? JSON.parse(raw) : {};
    } catch (e) {
      // Подія все одно обробиться — з порожнім тілом, тобто без cwd і
      // транскрипту. Без цього рядка сесія просто «губила» проєкт.
      log.warnRepeated(`hook-json ${event}`, `хук ${event}: тіло не JSON (${raw.length} байт)`, e);
    }

    try {
      events.handle(event, payload, {
        agent: headerUtf8(req.headers['x-agent']),
        label: headerUtf8(req.headers['x-claude-label']),
        term: headerUtf8(req.headers['x-term-program']),
        appBundle: headerUtf8(req.headers['x-app-bundle']),
        tmuxPane: headerUtf8(req.headers['x-tmux-pane']),
        hookPpid: headerUtf8(req.headers['x-hook-ppid']),
      });
    } catch (e) {
      log.error(`хук ${event} (сесія ${String(payload.session_id || '?').slice(0, 8)})`, e);
    }
    return;
  }

  // Примусове оновлення на вимогу — кнопка «Оновити список» у програмі.
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
    } catch (e) {
      // Архів не критичний для оновлення — відповідаємо далі, але слід лишаємо.
      log.warnRepeated('refresh-archive', 'оновлення на вимогу: архів', e);
    }

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

  // Колір та іконка проєкту.
  if (req.method === 'POST' && p === '/projects/settings') {
    const raw = await readBody(req);
    let body = {};
    try { body = JSON.parse(raw); } catch { return fail(res, 400, 'err.badJson'); }

    if (!body.path) return fail(res, 400, 'err.missing', { field: 'path' });

    const updated = projects.updateSettings(body.path, body.settings);
    if (!updated) return fail(res, 404, 'err.noProject');

    log.info(`налаштування проєкту ${updated.name} оновлено`);
    return json(res, 200, { ok: true, project: updated });
  }

  // Своя назва сесії та вимикач її сповіщень.
  if (req.method === 'POST' && p === '/sessions/settings') {
    const raw = await readBody(req);
    let body = {};
    try { body = JSON.parse(raw); } catch { return fail(res, 400, 'err.badJson'); }

    if (!body.sid) return fail(res, 400, 'err.missing', { field: 'sid' });

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
    try { body = JSON.parse(raw); } catch { return fail(res, 400, 'err.badJson'); }

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
  if (req.method === 'POST' && p === '/sessions/spawn') {
    const raw = await readBody(req);
    let body = {};
    try { body = JSON.parse(raw); } catch { return fail(res, 400, 'err.badJson'); }

    if (!body.projectPath) return fail(res, 400, 'err.missing', { field: 'projectPath' });

    try {
      const entry = terminals.start({
        projectPath: body.projectPath,
        label: body.label || '',
        prompt: body.prompt || '',
      });
      return json(res, 200, { ok: true, sid: entry.sid, label: entry.label });
    } catch (err) {
      return failErr(res, 400, err);
    }
  }

  // Написати в сесію так, ніби текст набрали з клавіатури.
  if (req.method === 'POST' && p === '/sessions/input') {
    const raw = await readBody(req);
    let body = {};
    try { body = JSON.parse(raw); } catch { return fail(res, 400, 'err.badJson'); }

    if (!body.sid || !body.text) {
      return fail(res, 400, 'err.needSidText');
    }

    const short = body.sid.slice(0, 8);
    // Сам текст у лог не йде: ~/.laserbeak читає вся група staff, а це
    // слова людини. Довжини досить, щоб зіставити з тим, що дійшло.
    const size = `${String(body.text).length} симв.`;

    try {
      const { via } = input.send(body.sid, body.text);
      log.info(`ввід у сесію ${short} (${via}): ${size}`);
      return json(res, 200, { ok: true, via });
    } catch (err) {
      return failErr(res, 409, err);
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
    try { body = JSON.parse(raw); } catch { return fail(res, 400, 'err.badJson'); }

    // Один знімок приходить полями самого тіла, послідовність — масивом
    // `shots`. Далі обидва випадки — це просто список.
    const list = Array.isArray(body.shots) ? body.shots : [body];

    if (!body.sid || !list.length || list.some((s) => !s || !s.image)) {
      return fail(res, 400, 'err.needSidImage');
    }
    if (list.length > shots.MAX_SERIES) {
      return fail(res, 400, 'err.tooManyShots', { max: shots.MAX_SERIES });
    }

    if (!state.get(body.sid) && !terminals.isHosted(body.sid)) {
      return fail(res, 404, 'err.noSession');
    }

    // Перевіряємо шлях у сесію до того, як писати файл: інакше на диску
    // лишався б смітник щоразу, коли сесію запущено без посередника.
    if (!input.canSend(body.sid)) {
      return fail(res, 409, 'err.noWayIn');
    }

    let saved;
    try {
      saved = shots.save({ sid: body.sid, images: list.map((s) => s.image) });
    } catch (err) {
      return failErr(res, 400, err);
    }

    const described = list.map((s, i) => ({
      file: saved[i].file,
      comment: s.comment,
      url: s.url,
      selector: s.selector,
      text: s.text,
      size: s.size,
      marked: s.marked === true,
    }));
    const text = described.length > 1 ? shots.sequence(described) : shots.prompt(described[0]);

    try {
      const { via } = input.send(body.sid, text);
      const bytes = saved.reduce((sum, f) => sum + f.bytes, 0);
      const what = saved.length > 1 ? `скріни зон ×${saved.length}` : 'скрін зони';
      log.info(`${what} → сесія ${body.sid.slice(0, 8)} (${via}, ${Math.round(bytes / 1024)} КБ)`);
      return json(res, 200, {
        ok: true, via, file: saved[0].file, files: saved.map((f) => f.file), bytes,
      });
    } catch (err) {
      return failErr(res, 409, err);
    }
  }

  // Слеш-команди Claude Code: модель, рівень зусиль, стиснення.
  //
  // Технічно це той самий ввід у сесію, але маршрути окремі й зі
  // списком дозволеного: програма має показувати справжні варіанти,
  // а не давати клієнту слати в сесію будь-який рядок як команду.
  if (req.method === 'POST' && p === '/sessions/command') {
    const raw = await readBody(req);
    let body = {};
    try { body = JSON.parse(raw); } catch { return fail(res, 400, 'err.badJson'); }

    const command = buildCommand(body);
    if (!command) {
      return fail(res, 400, 'err.badCommand');
    }

    if (!state.get(body.sid) && !terminals.isHosted(body.sid)) {
      return fail(res, 404, 'err.noSession');
    }

    // У Codex /model — інтерактивний вибір з іншими назвами, а рівень
    // зусиль задається інакше. Слати туди команди Claude Code не можна;
    // лишається /compact, який в обох означає те саме.
    if (state.get(body.sid)?.agent === 'codex' && !body.compact) {
      return fail(res, 409, 'err.notInCodex');
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
      return failErr(res, 409, err);
    }
  }

  if (req.method === 'POST' && p === '/sessions/interrupt') {
    const raw = await readBody(req);
    let body = {};
    try { body = JSON.parse(raw); } catch { return fail(res, 400, 'err.badJson'); }

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
    try { body = JSON.parse(raw); } catch { return fail(res, 400, 'err.badJson'); }

    const session = state.get(body.sid);
    if (!session) return fail(res, 404, 'err.noSession');

    // Shift+Tab і смужка з режимом — це інтерфейс Claude Code. У Codex
    // режими — політика підтверджень і sandbox, і тиснути там Shift+Tab
    // наосліп означало б перемикати невідомо що.
    if (session.agent === 'codex') {
      return fail(res, 409, 'err.notInCodex');
    }

    const press = terminals.isHosted(body.sid)
      ? () => terminals.shiftTab(body.sid)
      : (session.tmuxPane ? () => tmux.shiftTab(session.tmuxPane) : null);

    if (!press) {
      return fail(res, 409, 'err.noWayIn');
    }

    try {
      const result = await modes.switchTo({
        session,
        target: body.mode,
        press,
      });
      return json(res, result.ok ? 200 : 409, { ok: result.ok, ...result });
    } catch (err) {
      return failErr(res, 400, err);
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
    try { body = JSON.parse(raw); } catch { return fail(res, 400, 'err.badJson'); }

    const session = state.get(body.sid);
    if (!session) return fail(res, 404, 'err.noSession');

    state.remove(body.sid);
    modes.forget(body.sid);
    state.record({
      sid: body.sid,
      label: session.label,
      project: session.project,
      kind: 'session-end',
      message: t('history.forgotten'),
    });

    log.info(`сесію ${session.label} прибрано вручну`);
    return json(res, 200, { ok: true });
  }

  if (req.method === 'POST' && p === '/sessions/stop') {
    const raw = await readBody(req);
    let body = {};
    try { body = JSON.parse(raw); } catch { return fail(res, 400, 'err.badJson'); }

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
    if (!meta) return fail(res, 404, 'err.noSessionInArchive');

    return json(res, 200, {
      ok: true,
      session: meta,
      messages: archive.read(sid, {
        limit: Number(url.searchParams.get('limit') || 0),
        includeSidechain: url.searchParams.get('subagents') === '1',
      }),
    });
  }

  // Загальні налаштування: мова, банери, звуки, оновлення.
  if (req.method === 'GET' && p === '/settings') {
    return json(res, 200, { ok: true, ...settings.get() });
  }

  if (req.method === 'POST' && p === '/settings') {
    const raw = await readBody(req);
    let body = {};
    try { body = JSON.parse(raw); } catch { return fail(res, 400, 'err.badJson'); }

    try {
      const saved = settings.save(body);
      log.info(`налаштування: ${JSON.stringify(saved.patch)}`);

      // Щойно ввімкнули перевірку — не чекаємо шість годин до першої.
      if (saved.patch.updates?.check) {
        updates.check({ quiet: true }).catch((e) => log.warn('перевірка оновлень після ввімкнення', e));
      }

      delete saved.patch;
      return json(res, 200, { ok: true, ...saved });
    } catch (err) {
      if (err.code === 'EINVAL') return failErr(res, 400, err);
      if (err.code === 'EBROKEN') return fail(res, 409, 'err.configBroken');
      throw err;
    }
  }

  // Оновлення з GitHub: лише перевірка й підказка, що виконати, —
  // ставить людина сама, див. src/updates.js.
  if (req.method === 'GET' && p === '/update') {
    return json(res, 200, { ok: true, update: updates.details() });
  }

  if (req.method === 'POST' && p === '/update/check') {
    await updates.check({ quiet: true });
    return json(res, 200, { ok: true, update: updates.details() });
  }

  if (p === '/health') {
    return json(res, 200, { ok: true, pid: process.pid, outbox: outbox.stats() });
  }

  fail(res, 404, 'err.notFound');
}

// Обробник, що кинув виняток, раніше лишав запит висіти: відповіді не
// було, клієнт чекав до свого таймауту, а в лозі — лише «unhandled» без
// маршруту. Тепер клієнт одразу отримує 500, а errors.log — що і де.
function createServer() {
  return http.createServer((req, res) => {
    handle(req, res).catch((err) => {
      log.error(`${req.method} ${req.url.split('?')[0]} впав`, err);
      if (!res.headersSent) fail(res, 500, 'err.internal');
      else res.destroy();
    });
  });
}

module.exports = { createServer };
