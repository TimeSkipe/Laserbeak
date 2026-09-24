// Мова розширення: як у браузері або вибрана вручну у вікні налаштувань.
//
// chrome.i18n прибитий до мови інтерфейсу браузера, і перемкнути його
// не можна ніяк. Тож для ручного вибору таблицю з
// _locales/<мова>/messages.json читаємо самі, а підстановку
// плейсхолдерів повторюємо за ним — тексти лишаються там само, де були.
//
// Файл підключається в трьох місцях: у service worker (importScripts),
// у вікно налаштувань (<script>) і на сторінку разом з оверлеєм. На
// сторінку його вставляють при кожному виділенні, тож на верхньому рівні
// лише `var`: повторне `const` зламало б другий запуск.

var LaserbeakI18n = globalThis.LaserbeakI18n || (() => {
  const LANGUAGES = ['uk', 'en', 'cs'];

  // Як chrome.i18n: `$NAME$` у тексті → placeholders.name.content, а там
  // `$1`…`$9` — аргументи по порядку.
  function format(entry, args) {
    return entry.message.replace(/\$(\w+)\$/g, (whole, name) => {
      const ph = entry.placeholders?.[name.toLowerCase()];
      return ph ? ph.content.replace(/\$(\d)/g, (_, n) => args[n - 1] ?? '') : whole;
    });
  }

  // Таблиця вибраної мови; null — як у браузері. Файли розширення
  // читають service worker і вікно налаштувань; сторінці таблицю
  // передають повідомленням, щоб не робити _locales доступним звідусіль.
  async function load(language) {
    if (!LANGUAGES.includes(language)) return null;
    const res = await fetch(chrome.runtime.getURL(`_locales/${language}/messages.json`));
    return res.json();
  }

  // msg над конкретною таблицею. Чого в ній немає — питаємо браузер:
  // краще рядок іншою мовою, ніж порожня кнопка.
  const bind = (table) => (key, ...args) => {
    const values = args.map(String);
    return table?.[key] ? format(table[key], values) : chrome.i18n.getMessage(key, values);
  };

  return { LANGUAGES, format, load, bind };
})();
