'use strict';

// Конфіг живе у ~/.laserbeak/config.json і перечитується на льоту.

const fs = require('fs');
const os = require('os');
const { CONFIG_PATH } = require('./paths');
const log = require('./log');

const DEFAULTS = {
  port: 8787,

  // Демон нікуди не виглядає: телефон ходить через програму на маку
  // зашифрованим каналом, а вона вже стукає сюди по 127.0.0.1.
  //
  // Постав "0.0.0.0", щоб увімкнути ще й запасний шлях по HTTP — тоді
  // телефон працюватиме навіть із закритою програмою, але трафік у
  // локальній мережі буде відкритий (захищений лише ключем).
  bindHost: '127.0.0.1',

  // Під цим іменем ноут з'являється в застосунку на телефоні.
  serviceName: os.hostname().replace(/\.local$/, ''),

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
  },

  // Системні звуки macOS: /System/Library/Sounds. "" = тихо.
  sounds: {
    stop: 'Glass',
    permission: 'Funk',
    idle: 'Tink',
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
    } catch {
      setTimeout(attach, 5000);
    }
  };
  attach();
}

load();

module.exports = { DEFAULTS, get: () => current, load, watch };
