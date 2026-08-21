'use strict';

// Власні налаштування окремих сесій: своя назва та вимикач сповіщень.
//
// Зберігаються на диску й застосовуються на боці демона, тому нова назва
// діє глобально — у вікні на маку, на телефоні і в самих банерах. Клієнти
// нічого не перекладають у себе, вони бачать уже готове.

const fs = require('fs');
const path = require('path');
const { DATA_DIR } = require('./paths');
const log = require('./log');

const STORE_PATH = path.join(DATA_DIR, 'sessions.json');

/** sid -> { alias?: string, notify?: boolean } */
const overrides = new Map();

let saveTimer = null;

function load() {
  try {
    const raw = JSON.parse(fs.readFileSync(STORE_PATH, 'utf8'));
    for (const [sid, value] of Object.entries(raw.sessions || {})) {
      if (value && typeof value === 'object') overrides.set(sid, value);
    }
    if (overrides.size) log.info(`налаштувань сесій у памʼяті: ${overrides.size}`);
  } catch (err) {
    if (err.code !== 'ENOENT') log.warn(`sessions.json: ${err.message}`);
  }
}

function save() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    const body = JSON.stringify({ sessions: Object.fromEntries(overrides) }, null, 2);
    fs.writeFile(STORE_PATH, body, (err) => {
      if (err) log.error(`sessions.json: ${err.message}`);
    });
  }, 500);
}

function get(sid) {
  return overrides.get(sid) || null;
}

/**
 * Часткове оновлення: передане замінюється, решта лишається як була.
 * Порожня назва означає "повернути початкову мітку".
 */
function update(sid, patch) {
  if (!sid) return null;

  const next = { ...(overrides.get(sid) || {}) };

  if ('alias' in patch) {
    const alias = String(patch.alias || '').trim();
    if (alias) next.alias = alias;
    else delete next.alias;
  }

  if ('notify' in patch) {
    next.notify = patch.notify !== false;
  }

  if (Object.keys(next).length) overrides.set(sid, next);
  else overrides.delete(sid);

  save();
  return overrides.get(sid) || {};
}

/** Чи слати банери для цієї сесії. За замовчуванням — так. */
function isNotifyEnabled(sid) {
  return get(sid)?.notify !== false;
}

/** Назва, яку треба показувати: своя, якщо задана, інакше мітка з CLAUDE_LABEL. */
function displayName(sid, fallback) {
  return get(sid)?.alias || fallback;
}

load();

module.exports = { get, update, isNotifyEnabled, displayName, STORE_PATH };
