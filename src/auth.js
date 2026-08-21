'use strict';

// Ключ доступу до демона.
//
// Демон слухає 0.0.0.0, щоб телефон бачив його у Wi-Fi. Без ключа це
// означало б, що будь-хто в тій самій мережі читає назви проєктів,
// переписку — і, що гірше, шле запити прямо в твої сесії.
//
// Тому все, що приходить не з цього компʼютера, має принести ключ:
//
//   Authorization: Bearer <ключ>
//
// Запити з 127.0.0.1 ключа не потребують: там і так може писати лише
// той, хто вже сидить за цим компʼютером.
//
// Той самий ключ служить паролем для зашифрованого зʼєднання з
// телефоном (TLS-PSK). Телефон отримує його один раз — із QR-коду,
// показаного на екрані мака.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { DATA_DIR } = require('./paths');
const log = require('./log');

const TOKEN_PATH = path.join(DATA_DIR, 'token');

// 24 байти — 32 символи base64url. Досить, щоб перебір був безнадійним,
// і достатньо коротко, щоб QR-код лишався розрідженим.
const TOKEN_BYTES = 24;

let token = '';

function generate() {
  return crypto.randomBytes(TOKEN_BYTES).toString('base64url');
}

/**
 * Записати ключ так, щоб його не прочитали інші користувачі машини.
 * Права 0600 ставимо саме при створенні, а не після — інакше лишається
 * вікно, у якому файл читає хто завгодно.
 */
function write(value) {
  fs.writeFileSync(TOKEN_PATH, value + '\n', { mode: 0o600 });

  // Файл міг існувати раніше з іншими правами: writeFileSync застосовує
  // mode тільки до новоствореного.
  try {
    fs.chmodSync(TOKEN_PATH, 0o600);
  } catch { /* не критично */ }
}

function load() {
  try {
    const saved = fs.readFileSync(TOKEN_PATH, 'utf8').trim();
    if (saved) {
      token = saved;
      return token;
    }
  } catch (err) {
    if (err.code !== 'ENOENT') log.warn(`token: ${err.message}`);
  }

  token = generate();
  write(token);
  log.info(`створив ключ доступу: ${TOKEN_PATH}`);
  return token;
}

function get() {
  return token || load();
}

/** Новий ключ. Усі підключені телефони доведеться під'єднати наново. */
function rotate() {
  token = generate();
  write(token);
  log.info('ключ доступу змінено — телефони треба підключити наново');
  return token;
}

/** Порівняння, що не видає довжиною збігу, скільки символів угадано. */
function matches(candidate) {
  const expected = get();
  if (!candidate || typeof candidate !== 'string') return false;

  const a = Buffer.from(candidate, 'utf8');
  const b = Buffer.from(expected, 'utf8');
  if (a.length !== b.length) return false;

  return crypto.timingSafeEqual(a, b);
}

/** Ключ із заголовка запиту: приймаємо і "Bearer x", і голий ключ. */
function fromRequest(req) {
  const header = req.headers.authorization || req.headers['x-laserbeak-token'] || '';
  const text = String(header).trim();
  return text.toLowerCase().startsWith('bearer ') ? text.slice(7).trim() : text;
}

function isAuthorized(req) {
  return matches(fromRequest(req));
}

load();

module.exports = { get, rotate, matches, isAuthorized, TOKEN_PATH };
