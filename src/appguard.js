'use strict';

// Нагляд за програмою на маку.
//
// НАВІЩО. Програма більше не просто показує вікно: вона тримає єдиний
// зашифрований канал до телефона. Демон замкнений на 127.0.0.1, тож
// якщо програма лежить, телефон не бачить нічого. Це надто важливо, щоб
// залежати від того, чи не закрив ти її випадково.
//
// ЧОМУ НЕ KeepAlive У LAUNCHD. Програму треба запускати через `open` —
// інакше її не реєструє LaunchServices, і сповіщення можуть не
// працювати (див. docs/decisions.md). Але `open` одразу завершується,
// віддавши роботу LaunchServices, тому launchd вважав би це падінням і
// перезапускав `open` кожні десять секунд вічно.
//
// ЯК МИ ЗНАЄМО, ЩО ВОНА ЖИВА. Не через таблицю процесів: процес може
// висіти, не роблячи нічого. Надійніше — черга сповіщень: жива програма
// постійно тримає відкритий запит на /events/wait. Тобто ми перевіряємо
// не «чи запущено», а «чи на звʼязку», і це саме те, що потрібно.
//
// ЯК ВИЙТИ ПО-СПРАВЖНЬОМУ. Пункт «Вийти» в меню-барі лишає по собі
// файл-позначку. Доки вона є, ми програму не чіпаємо — інакше вихід
// виглядав би зламаним: закрив, а воно повернулось. Позначку прибирає
// сама програма при наступному запуску.

const fs = require('fs');
const path = require('path');
const { execFile } = require('child_process');
const { DATA_DIR, HOME } = require('./paths');
const outbox = require('./outbox');
const log = require('./log');

const QUIT_FLAG = path.join(DATA_DIR, 'app-quit');

const CHECK_MS = 10_000;

// Скільки програма має мовчати, перш ніж ми вважатимемо її мертвою.
//
// Тут легко помилитись, і я помилився: черга сама вважає клієнта живим
// ще 45 секунд після останнього запиту. Ці затримки не перекриваються, а
// **додаються** — тобто загальний час до підняття це 45 + оце число +
// такт перевірки. З 90 секундами програма поверталась аж за дві з
// половиною хвилини.
//
// Тож тут потрібен невеликий доважок, а не повноцінне вікно: черга вже
// все почекала за нас. Разом виходить близько хвилини.
const SILENCE_MS = 15_000;

// І як часто дозволено піднімати. Якщо програма падає одразу після
// старту, краще спробувати раз на дві хвилини, ніж крутити це по колу.
const RETRY_MS = 120_000;

// Скільки не чіпати програму після того, як мак прокинувся.
//
// Спати мак може по десять разів за ніч, і щоразу це виглядало як
// падіння: доки він спав, програма, ясна річ, нічого не питала. За добу
// набігало два десятки «мовчить — піднімаю» на порожньому місці.
//
// Насправді після прокидання їй просто треба мить, щоб підняти свій
// запит на /events/wait. Даємо хвилину.
const WAKE_GRACE_MS = 60_000;

const CANDIDATES = [
  '/Applications/Laserbeak.app',
  path.join(HOME, 'Applications', 'Laserbeak.app'),
];

let silentSince = 0;
let lastRevive = 0;
let lastCheck = 0;
let wokeAt = 0;
let timer = null;

/** Де лежить програма. Шлях може змінитись, тому шукаємо щоразу. */
function appPath() {
  for (const candidate of CANDIDATES) {
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

/** Чи вийшли з програми свідомо. */
function quitDeliberately() {
  return fs.existsSync(QUIT_FLAG);
}

function revive(app) {
  // Ті самі аргументи, що й у LaunchAgent: -g щоб не лізти на передній
  // план, --background щоб не відкривати вікно.
  execFile('/usr/bin/open', ['-g', '-a', app, '--args', '--background'], (err) => {
    if (err) log.warn(`програму підняти не вдалося: ${err.message}`);
  });
}

function check() {
  const now = Date.now();

  // Таймер не цокає, доки мак спить. Тому велика діра між тактами — це
  // не «програма мовчала пів години», це «нас тут не було». Розрізняти
  // обов'язково: інакше кожне нічне прокидання рахується за падіння.
  const gap = lastCheck ? now - lastCheck : 0;
  lastCheck = now;

  if (gap > CHECK_MS * 3) {
    silentSince = 0;
    wokeAt = now;
  }

  if (outbox.hasDesktopClient()) {
    silentSince = 0;
    return;
  }

  if (wokeAt && now - wokeAt < WAKE_GRACE_MS) return;

  if (!silentSince) {
    silentSince = now;
    return;
  }

  if (now - silentSince < SILENCE_MS) return;
  if (now - lastRevive < RETRY_MS) return;

  if (quitDeliberately()) return;

  const app = appPath();
  if (!app) {
    // Скаржимось не частіше, ніж пробували б піднімати.
    lastRevive = now;
    log.warn('програму на маку не знайдено — телефон лишиться без звʼязку');
    return;
  }

  lastRevive = now;
  log.info('програма на маку мовчить — піднімаю');
  revive(app);
}

function start() {
  if (timer) return;
  timer = setInterval(check, CHECK_MS);
  timer.unref();
}

function stop() {
  clearInterval(timer);
  timer = null;
}

module.exports = { start, stop, check, QUIT_FLAG, appPath };
