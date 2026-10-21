'use strict';

// Конфіг живе у ~/.laserbeak/config.json і перечитується на льоту.

const fs = require('fs');
const { CONFIG_PATH } = require('./paths');
const log = require('./log');

const DEFAULTS = {
  // Слухаємо лише 127.0.0.1, і це не налаштовується: у демона немає
  // клієнтів поза цим компʼютером. Порт — можна.
  port: 8787,

  // Мова всього, що бачить людина: банерів, історії, помилок API,
  // вікна програми й розширення браузера. "auto" (як у системі), "uk",
  // "en", "cs". Програма й розширення беруть її звідси ж — див. i18n.js.
  language: 'auto',

  // Розширення браузера, якому дозволено стукати в демон. Порожній
  // рядок — будь-яке розширення; сторінки з мережі не пройдуть однаково,
  // бо Origin вони підробити не можуть.
  //
  // Id сталий, бо в manifest.json вписано публічний ключ — інакше Chrome
  // видавав би нову адресу після кожної переустановки.
  extensionId: 'bcibihhnnjblcbgehfemebkkdcnhjmnf',

  // Які події показують банер на маку.
  notify: {
    stop: true,        // Claude закінчив турн
    permission: true,  // потрібен дозвіл або схвалення плану
    // Нагадування «сесія чекає на твій ввід». Прилітає приблизно через
    // хвилину після завершення відповіді, тобто дублює stop — тому
    // вимкнене. Увімкни, якщо stop вимкнено, а нагадування потрібне.
    idle: false,
    update: true,      // на GitHub зʼявилась нова версія Laserbeak
  },

  // Системні звуки macOS: /System/Library/Sounds. "" = тихо.
  sounds: {
    stop: 'Glass',
    permission: 'Funk',
    idle: 'Tink',
    update: 'Ping',
  },

  // Перевірка нової версії на GitHub — див. src/updates.js.
  updates: {
    check: true,
  },

  historySize: 200,
};

function deepMerge(base, override) {
  if (!override || typeof override !== 'object' || Array.isArray(override)) return base;
  const out = { ...base };
  for (const [k, v] of Object.entries(override)) {
    if (k.startsWith('_')) continue;
    out[k] = (v && typeof v === 'object' && !Array.isArray(v) && typeof base[k] === 'object')
      ? deepMerge(base[k], v)
      : v;
  }
  return out;
}

let current = { ...DEFAULTS };

function load() {
  try {
    current = deepMerge(DEFAULTS, JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8')));
    return true;
  } catch (err) {
    if (err.code === 'ENOENT') { current = { ...DEFAULTS }; return true; }
    log.error(`config.json пошкоджений (${err.message}) — лишаю попередні значення`);
    return false;
  }
}

function watch() {
  let debounce = null;
  const attach = () => {
    try {
      fs.watch(CONFIG_PATH, { persistent: false }, () => {
        clearTimeout(debounce);
        debounce = setTimeout(() => { if (load()) log.info('config перечитано'); }, 80);
      });
    } catch (err) {
      log.warnRepeated('config-watch', 'стежити за config.json не вийшло, пробую знову за 5 с', err);
      setTimeout(attach, 5000);
    }
  };
  attach();
}

/**
 * Записати зміну в config.json, не чіпаючи решти файла.
 *
 * Зливаємо з тим, що лежить у файлі, а не з уже доповненим типовими
 * значеннями: інакше перше ж збереження з програми вписало б у файл усі
 * DEFAULTS, і нове типове значення в коді вже ніколи не дійшло б до
 * користувача.
 *
 * Пишемо на місце, а не через тимчасовий файл і rename: fs.watch стежить
 * за конкретним файлом, і після підміни дивився б на старий.
 *
 * Пошкоджений файл не переписуємо — там чиїсь правки руками, і втратити
 * їх гірше, ніж не зберегти перемикач.
 */
function update(patch) {
  let raw = {};
  try {
    raw = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
  } catch (err) {
    if (err.code !== 'ENOENT') {
      const broken = new Error('config.json is broken');
      broken.code = 'EBROKEN';
      throw broken;
    }
  }

  fs.writeFileSync(CONFIG_PATH, JSON.stringify(deepMerge(raw, patch), null, 2) + '\n');
  load();
  return current;
}

load();

module.exports = { DEFAULTS, get: () => current, load, watch, update };
