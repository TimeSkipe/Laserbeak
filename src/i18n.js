'use strict';

// Тексти, які бачить користувач.
//
// Тут лише те, що справді доходить до людини: банери, історія подій і
// помилки, які повертає API. Логи не перекладаємо навмисно — їх читає
// той, хто відкрив daemon.log, і шукати в них «сесію не знайдено» трьома
// мовами було б гірше, ніж однією.
//
// Чому переклад тут, а не в програмах: банер складає саме Laserbeak, і
// в запасному шляху через terminal-notifier ніякої програми взагалі
// немає. Клієнти нічого не обчислюють — правило те саме, що для решти.
//
// Мову задають трьома способами, від сильнішого до слабшого:
// LASERBEAK_LANG, config.language, «як у системі» (AppleLocale, потім
// $LANG). Перше зручне для перевірки, друге — те, що вибирають під час
// установки.

const { execFileSync } = require('child_process');
const config = require('./config');

const DEFAULT = 'en';

const STRINGS = {
  uk: {
    'notify.done': 'Закінчила роботу',
    'notify.permission': 'Потрібен дозвіл',
    'notify.idle': 'Чекає на твій ввід',

    'history.done': 'Готово за {duration}',
    'history.doneNoTime': 'Готово',
    'history.opened': 'сесія відкрита',
    'history.closed': 'сесія закрита',
    'history.forgotten': 'прибрано вручну',

    'tokens': '{count} токенів',
    'dur.seconds': '{s}с',
    'dur.minutes': '{m}хв {s}с',
    'dur.hours': '{h}год {m}хв',

    'err.noSession': 'сесії немає',
    'err.noSessionInArchive': 'сесії немає в архіві',
    'err.noProject': 'проєкт не знайдено',
    'err.noWayIn': 'сесію запущено без посередника — перезапусти її командою start',
    'err.needToken': 'потрібен ключ доступу — підключи телефон QR-кодом заново',
    'err.badOrigin': 'цьому джерелу сюди не можна',
    'err.needSidText': 'потрібні sid і text',
    'err.needSidImage': 'потрібні sid і image',
    'err.badCommand': 'невідома команда або значення',
    'err.required': 'обовʼязковий',
  },

  en: {
    'notify.done': 'Finished',
    'notify.permission': 'Permission needed',
    'notify.idle': 'Waiting for your input',

    'history.done': 'Done in {duration}',
    'history.doneNoTime': 'Done',
    'history.opened': 'session opened',
    'history.closed': 'session closed',
    'history.forgotten': 'removed by hand',

    'tokens': '{count} tokens',
    'dur.seconds': '{s}s',
    'dur.minutes': '{m}m {s}s',
    'dur.hours': '{h}h {m}m',

    'err.noSession': 'no such session',
    'err.noSessionInArchive': 'no such session in the archive',
    'err.noProject': 'project not found',
    'err.noWayIn': 'this session was started without a go-between — restart it with the start command',
    'err.needToken': 'access key required — pair the phone with the QR code again',
    'err.badOrigin': 'this origin is not allowed here',
    'err.needSidText': 'sid and text are required',
    'err.needSidImage': 'sid and image are required',
    'err.badCommand': 'unknown command or value',
    'err.required': 'required',
  },

  cs: {
    'notify.done': 'Hotovo',
    'notify.permission': 'Vyžaduje svolení',
    'notify.idle': 'Čeká na tvůj vstup',

    'history.done': 'Hotovo za {duration}',
    'history.doneNoTime': 'Hotovo',
    'history.opened': 'relace otevřena',
    'history.closed': 'relace uzavřena',
    'history.forgotten': 'odstraněno ručně',

    'tokens': '{count} tokenů',
    'dur.seconds': '{s} s',
    'dur.minutes': '{m} min {s} s',
    'dur.hours': '{h} h {m} min',

    'err.noSession': 'relace neexistuje',
    'err.noSessionInArchive': 'relace není v archivu',
    'err.noProject': 'projekt nenalezen',
    'err.noWayIn': 'relace byla spuštěna bez prostředníka — restartuj ji příkazem start',
    'err.needToken': 'je potřeba přístupový klíč — spáruj telefon znovu QR kódem',
    'err.badOrigin': 'tento zdroj sem nesmí',
    'err.needSidText': 'je potřeba sid a text',
    'err.needSidImage': 'je potřeba sid a image',
    'err.badCommand': 'neznámý příkaz nebo hodnota',
    'err.required': 'povinný',
  },
};

// Мову системи питаємо один раз: `defaults` коштує помітно дорожче за
// читання змінної, а посеред роботи вона не змінюється.
let systemLanguage = null;

function detectSystem() {
  if (systemLanguage) return systemLanguage;

  try {
    const locale = execFileSync('/usr/bin/defaults', ['read', '-g', 'AppleLocale'], {
      encoding: 'utf8',
      timeout: 2000,
    }).trim();
    systemLanguage = locale.slice(0, 2).toLowerCase();
  } catch {
    systemLanguage = String(process.env.LANG || '').slice(0, 2).toLowerCase();
  }

  if (!STRINGS[systemLanguage]) systemLanguage = DEFAULT;
  return systemLanguage;
}

// Порядок такий:
//
//   LASERBEAK_LANG   разовий запуск чи налагодження — сильніший за все
//   config.language  те, що вибрали під час установки
//   "auto"           як у системі
//
// Змінна оточення попереду навмисно: перевірити чужу мову має бути
// можна одним запуском, не чіпаючи конфіг і не перезапускаючи демон.
function current() {
  const fromEnv = String(process.env.LASERBEAK_LANG || '').toLowerCase();
  if (STRINGS[fromEnv]) return fromEnv;

  const wanted = config.get().language || 'auto';
  if (wanted === 'auto') return detectSystem();
  return STRINGS[wanted] ? wanted : DEFAULT;
}

/**
 * Переклад із підстановкою: t('tokens', { count: '45k' }).
 *
 * Невідомий ключ повертається як є — краще побачити 'notify.oops' у
 * банері, ніж порожній рядок, який нічого не пояснює.
 */
function t(key, params = {}) {
  const lang = current();
  const template = STRINGS[lang]?.[key] ?? STRINGS[DEFAULT]?.[key] ?? key;

  return template.replace(/\{(\w+)\}/g, (whole, name) => (
    Object.prototype.hasOwnProperty.call(params, name) ? String(params[name]) : whole
  ));
}

module.exports = { t, current, LANGUAGES: Object.keys(STRINGS) };
