'use strict';

// Тексти для Node-скриптів установки — з тієї самої таблиці, що й у bash
// (scripts/lang.sh). Переклад живе в одному місці й перевіряється одним
// npm run check:l10n; тут його лише читають.
//
// Мова — за тим самим правилом, що в lang.sh: LB_LANG → LASERBEAK_LANG →
// вибір у config.json → мова системи → en.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const LANGUAGES = ['uk', 'en', 'cs', 'ru', 'kk'];
const TABLE_PATH = path.join(__dirname, 'lang.sh');
const ENTRY = /^\s+([a-z]{2}):([\w.]+)\) text=(['"])(.*)\3 ;;$/gm;

function load() {
  const table = {};
  for (const m of fs.readFileSync(TABLE_PATH, 'utf8').matchAll(ENTRY)) {
    (table[m[2]] ||= {})[m[1]] = m[4];
  }
  return table;
}

function systemLanguage() {
  try {
    const out = execFileSync('/usr/bin/defaults', ['read', '-g', 'AppleLanguages'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 2000,
    });
    const codes = out.split('\n').map((line) => line.replace(/[\s",()]/g, '').split(/[-_]/)[0]);
    return codes.find((code) => LANGUAGES.includes(code)) || 'en';
  } catch {
    return 'en';
  }
}

function detect() {
  for (const want of [process.env.LB_LANG, process.env.LASERBEAK_LANG]) {
    if (LANGUAGES.includes(want)) return want;
  }
  try {
    const cfg = JSON.parse(fs.readFileSync(path.join(os.homedir(), '.laserbeak', 'config.json'), 'utf8'));
    if (LANGUAGES.includes(cfg.language)) return cfg.language;
  } catch { /* конфіга ще немає — перша установка */ }
  return systemLanguage();
}

const table = load();
const lang = detect();

/** Текст за ключем; `%s` підставляються аргументами по черзі, як у printf. */
function t(key, ...args) {
  const template = table[key]?.[lang] ?? table[key]?.en ?? key;
  let i = 0;
  return template.replace(/%s/g, () => String(args[i++] ?? ''));
}

module.exports = { t, lang, LANGUAGES };
