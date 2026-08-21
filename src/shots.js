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
function fileName(sid, ext) {
  const d = new Date();
  const p2 = (n) => String(n).padStart(2, '0');
  const stamp = `${d.getFullYear()}${p2(d.getMonth() + 1)}${p2(d.getDate())}`
    + `-${p2(d.getHours())}${p2(d.getMinutes())}${p2(d.getSeconds())}`;
  return `${sid.slice(0, 8)}-${stamp}${ext}`;
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
 * Зберегти картинку й повернути шлях до неї.
 *
 * @param {{sid: string, image: string}} params
 * @returns {{file: string, bytes: number}}
 */
function save({ sid, image }) {
  const { buf, ext } = decodeDataUrl(image);

  fs.mkdirSync(paths.SHOTS_DIR, { recursive: true });
  const file = path.join(paths.SHOTS_DIR, fileName(sid, ext));
  fs.writeFileSync(file, buf);
  sweep();

  return { file, bytes: buf.length };
}

// Переноси рядків усередині запиту — це Enter, тобто відправка. Текст,
// зібраний тут, іде в сесію як є, тому він мусить лишатись однорядковим:
// інакше запит полетить частинами, і сесія побачить обрізок.
function flat(value) {
  return String(value || '').replace(/\s+/g, ' ').trim();
}

/**
 * Текст, який побачить сесія. Спершу вказівка подивитись картинку —
 * інакше Claude відповідає на коментар, не відкривши її.
 *
 * @param {{file: string, comment?: string, url?: string,
 *          selector?: string, text?: string, size?: string}} shot
 */
function prompt(shot) {
  const tail = [];

  const comment = flat(shot.comment);
  if (comment) tail.push(/[.!?]$/.test(comment) ? comment : `${comment}.`);

  const where = [];
  if (shot.selector) where.push(`елемент ${flat(shot.selector)}`);
  if (shot.text) where.push(`текст «${flat(shot.text).slice(0, 80)}»`);
  if (shot.url) where.push(flat(shot.url));
  if (where.length) tail.push(`${tail.length ? 'Це' : 'це'} ${where.join(', ')}.`);

  if (shot.size) tail.push(`Зона ${flat(shot.size)}.`);

  // Тире, а не крапка: крапка одразу після .png приклеїлась би до шляху,
  // і Read пішов би шукати неіснуючий файл.
  const head = `Подивись скріншот: ${shot.file}`;
  return tail.length ? `${head} — ${tail.join(' ')}` : head;
}

module.exports = { save, prompt, KEEP_FILES, KEEP_DAYS };
