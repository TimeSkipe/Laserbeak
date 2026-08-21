'use strict';

// Черга сповіщень для застосунку на маку.
//
// Банери показує сама програма Laserbeak, а не сторонній terminal-notifier —
// тому в Центрі сповіщень вони мають її ім'я та іконку, групуються під нею
// і поводяться як сповіщення звичайної програми.
//
// Доставка миттєва, без опитування: програма тримає один відкритий запит
// (long-poll), і щойно з'являється подія, відповідь приходить одразу.

const log = require('./log');

const MAX_ITEMS = 50;

// Скільки часу після останнього запиту програма вважається живою.
// Довше за таймаут очікування, бо між відповіддю і новим запитом
// є невелика пауза.
const CLIENT_ALIVE_MS = 45_000;

const items = [];
let seq = 0;
let waiters = [];
let lastClientAt = 0;

/** Покласти сповіщення в чергу і розбудити того, хто чекає. */
function push(notification) {
  seq += 1;
  const item = { seq, ts: Date.now(), ...notification };

  items.push(item);
  if (items.length > MAX_ITEMS) items.shift();

  const pending = waiters;
  waiters = [];
  for (const resolve of pending) resolve([item]);

  return item;
}

function since(afterSeq) {
  return items.filter((i) => i.seq > afterSeq);
}

/**
 * Чекати на нові сповіщення.
 * Якщо вони вже є — віддаємо одразу; інакше тримаємо запит до таймауту.
 */
function wait(afterSeq, timeoutMs) {
  lastClientAt = Date.now();

  const ready = since(afterSeq);
  if (ready.length) return Promise.resolve(ready);

  return new Promise((resolve) => {
    const done = (list) => {
      clearTimeout(timer);
      resolve(list);
    };

    const timer = setTimeout(() => {
      waiters = waiters.filter((w) => w !== done);
      resolve([]);
    }, timeoutMs);

    waiters.push(done);
  });
}

/** Чи слухає нас програма на маку просто зараз. */
function hasDesktopClient() {
  return Date.now() - lastClientAt < CLIENT_ALIVE_MS;
}

function currentSeq() {
  return seq;
}

function stats() {
  return { seq, waiting: waiters.length, clientAlive: hasDesktopClient() };
}

module.exports = { push, since, wait, hasDesktopClient, currentSeq, stats };
