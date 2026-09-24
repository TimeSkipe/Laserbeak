'use strict';

// Скріншоти зон, надіслані з розширення браузера.
//
// Ввід у сесію текстовий: tmux send-keys шле символи, картинку туди не
// покладеш. Але Claude Code читає зображення з диска власним Read — тож
// картинка лягає у файл, а в сесію йде рядок зі шляхом до нього.
//
// Тобто це не новий канал, а звичайний ввід: input.js нічого не знає
// про скріншоти й знати не мусить.

const fs = require('fs');
const path = require('path');
const paths = require('./paths');
const log = require('./log');

// Скільки скрінів тримати. Вони потрібні рівно доти, доки сесія їх
// читає, тобто хвилини; але видаляти одразу не можна — сесія може
// повернутись до картинки посеред роботи.
const KEEP_FILES = 200;
const KEEP_DAYS = 7;

// Скільки знімків в одній послідовності. «Спершу тут, потім отут» рідко
// буває довшим за кілька кроків, а кожен знімок — ще мегабайт у тілі
// запиту й ще один Read у сесії.
const MAX_SERIES = 8;

const TYPES = {
  'image/png': '.png',
  'image/jpeg': '.jpg',
  'image/webp': '.webp',
};

// Тіло приходить як data URL — саме так canvas віддає картинку в
// розширенні, і так її не доводиться перекодовувати дорогою.
function decodeDataUrl(dataUrl) {
  const m = /^data:([^;,]+);base64,(.+)$/s.exec(String(dataUrl || ''));
  if (!m) throw new Error('очікував data URL із base64');

  const ext = TYPES[m[1]];
  if (!ext) throw new Error(`незрозумілий тип картинки: ${m[1]}`);

  const buf = Buffer.from(m[2], 'base64');
  if (!buf.length) throw new Error('порожня картинка');

  return { buf, ext };
}

// Імʼя читабельне навмисно: воно потрапляє в текст запиту, і в сесії
// видно, звідки картинка, ще до того як її відкрили.
//
// Знімки однієї послідовності пишуться в ту саму секунду — без номера
// вони перезаписали б один одного, і сесія тричі читала б останній.
function fileName(sid, ext, n) {
  const d = new Date();
  const p2 = (x) => String(x).padStart(2, '0');
  const stamp = `${d.getFullYear()}${p2(d.getMonth() + 1)}${p2(d.getDate())}`
    + `-${p2(d.getHours())}${p2(d.getMinutes())}${p2(d.getSeconds())}`;
  return `${sid.slice(0, 8)}-${stamp}${n ? `-${n}` : ''}${ext}`;
}

// Прибираємо при кожному записі: каталог малий, а окремий таймер заради
// десятка файлів — зайва сутність у daemon.js.
function sweep() {
  let entries;
  try {
    entries = fs.readdirSync(paths.SHOTS_DIR)
      .map((name) => {
        const full = path.join(paths.SHOTS_DIR, name);
        try { return { full, mtime: fs.statSync(full).mtimeMs }; } catch { return null; }
      })
      .filter(Boolean)
      .sort((a, b) => b.mtime - a.mtime);
  } catch {
    return;
  }

  const oldest = Date.now() - KEEP_DAYS * 24 * 60 * 60 * 1000;
  const doomed = entries.filter((e, i) => i >= KEEP_FILES || e.mtime < oldest);

  for (const e of doomed) {
    try { fs.unlinkSync(e.full); } catch { /* уже зникло — і добре */ }
  }
}

/**
 * Зберегти картинки й повернути шляхи до них — у тому ж порядку.
 *
 * Спершу розбираємо всі, потім пишемо: одна зіпсована картинка посеред
 * послідовності — і на диску не лишається жодної.
 *
 * @param {{sid: string, images: string[]}} params
 * @returns {Array<{file: string, bytes: number}>}
 */
function save({ sid, images }) {
  const decoded = images.map(decodeDataUrl);

  fs.mkdirSync(paths.SHOTS_DIR, { recursive: true });
  const saved = decoded.map(({ buf, ext }, i) => {
    const file = path.join(paths.SHOTS_DIR, fileName(sid, ext, decoded.length > 1 ? i + 1 : 0));
    fs.writeFileSync(file, buf);
    return { file, bytes: buf.length };
  });
  sweep();

  return saved;
}

// Переноси рядків усередині запиту — це Enter, тобто відправка. Текст,
// зібраний тут, іде в сесію як є, тому він мусить лишатись однорядковим:
// інакше запит полетить частинами, і сесія побачить обрізок.
function flat(value) {
  return String(value || '').replace(/\s+/g, ' ').trim();
}

// Червона рамка на знімку інтерфейсу виглядає як частина інтерфейсу.
// Не сказати про позначки — і сесія почне шукати в коді рамку, якої
// там ніколи не було.
const MARKS_ONE = 'позначки кольором на знімку мої, на сторінці їх немає.';
const MARKS_MANY = 'позначки кольором на знімках мої, на сторінках їх немає.';

const capital = (s) => s.charAt(0).toUpperCase() + s.slice(1);

// Що сказати про один знімок, крім шляху: коментар, де це, розмір.
// `withUrl: false` — адреса та сама, що в попереднього знімка, і
// повторювати її в кожному пункті послідовності немає сенсу.
function about(shot, { marks = false, withUrl = true } = {}) {
  const tail = [];

  const comment = flat(shot.comment);
  if (comment) tail.push(/[.!?]$/.test(comment) ? comment : `${comment}.`);

  if (marks) tail.push(tail.length ? capital(MARKS_ONE) : MARKS_ONE);

  const where = [];
  if (shot.selector) where.push(`елемент ${flat(shot.selector)}`);
  if (shot.text) where.push(`текст «${flat(shot.text).slice(0, 80)}»`);
  if (shot.url && withUrl) where.push(flat(shot.url));
  if (where.length) tail.push(`${tail.length ? 'Це' : 'це'} ${where.join(', ')}.`);

  if (shot.size) tail.push(`Зона ${flat(shot.size)}.`);

  return tail;
}

// Тире, а не крапка: крапка одразу після .png приклеїлась би до шляху,
// і Read пішов би шукати неіснуючий файл.
const withTail = (head, tail) => (tail.length ? `${head} — ${tail.join(' ')}` : head);

/**
 * Текст, який побачить сесія. Спершу вказівка подивитись картинку —
 * інакше Claude відповідає на коментар, не відкривши її.
 *
 * @param {{file: string, comment?: string, url?: string,
 *          selector?: string, text?: string, size?: string,
 *          marked?: boolean}} shot
 */
function prompt(shot) {
  return withTail(`Подивись скріншот: ${shot.file}`, about(shot, { marks: shot.marked }));
}

/**
 * Те саме для кількох знімків, знятих по черзі: «спершу тут, потім
 * отут». Один рядок, пункти пронумеровані — порядок і є сенс
 * послідовності, тож губити його не можна.
 *
 * @param {Array<Parameters<typeof prompt>[0]>} list
 */
function sequence(list) {
  const marked = list.some((s) => s.marked);
  const head = `Подивись скріншоти по черзі, це одна послідовність${marked ? `; ${MARKS_MANY}` : '.'}`;

  const items = list.map((shot, i) => withTail(
    `${i + 1}) ${shot.file}`,
    about(shot, { withUrl: !i || flat(shot.url) !== flat(list[i - 1].url) }),
  ));

  return `${head} ${items.join(' ')}`;
}

module.exports = { save, prompt, sequence, KEEP_FILES, KEEP_DAYS, MAX_SERIES };
