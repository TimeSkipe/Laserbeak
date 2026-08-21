'use strict';

// Реєстр проєктів.
//
// Сесія — річ тимчасова: закрив вікно, і її немає. Проєкт живе довше,
// тому список проєктів пам'ятається між перезапусками демона. Завдяки
// цьому у вікні програми видно всю робочу картину, а не лише те, що
// відкрито просто зараз.

const fs = require('fs');
const path = require('path');
const { DATA_DIR } = require('./paths');
const log = require('./log');

const STORE_PATH = path.join(DATA_DIR, 'projects.json');

/** path -> { path, name, firstSeen, lastSeen, editorBundleId } */
const known = new Map();

let saveTimer = null;

function load() {
  try {
    const raw = JSON.parse(fs.readFileSync(STORE_PATH, 'utf8'));
    for (const p of raw.projects || []) {
      if (p && p.path) known.set(p.path, p);
    }
    log.info(`проєктів у реєстрі: ${known.size}`);
  } catch (err) {
    if (err.code !== 'ENOENT') log.warn(`projects.json: ${err.message}`);
  }
}

function save() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    const body = JSON.stringify({ projects: [...known.values()] }, null, 2);
    fs.writeFile(STORE_PATH, body, (err) => {
      if (err) log.error(`projects.json: ${err.message}`);
    });
  }, 500);
}

/**
 * Записати, що в цьому каталозі щойно була активність.
 * @param {string} cwd повний шлях робочого каталогу сесії
 * @param {string} editorBundleId bundle id редактора, з якого запущено Claude
 */
function touch(cwd, editorBundleId) {
  if (!cwd) return null;

  const now = Date.now();
  const prev = known.get(cwd);

  const entry = {
    path: cwd,
    name: path.basename(cwd),
    firstSeen: prev?.firstSeen || now,
    lastSeen: now,
    // Запам'ятовуємо редактор, щоб потім відкрити проєкт саме в ньому.
    editorBundleId: editorBundleId || prev?.editorBundleId || '',
    // Власні налаштування проєкту: своя назва, свої звуки, що завгодно.
    // Правки користувача сюди не затираються активністю сесій.
    settings: prev?.settings || {},
  };

  known.set(cwd, entry);
  save();
  return entry;
}

/**
 * Змінити налаштування конкретного проєкту.
 * Приймає часткові дані — те, чого немає в патчі, лишається як було.
 */
function updateSettings(cwd, patch) {
  const entry = known.get(cwd);
  if (!entry) return null;

  const merged = { ...entry.settings, ...(patch || {}) };

  // Порожнє значення означає «як типово» — не тримаємо його у файлі.
  for (const [key, value] of Object.entries(merged)) {
    if (value === '' || value == null) delete merged[key];
  }

  entry.settings = merged;
  known.set(cwd, entry);
  save();
  return entry;
}

function list() {
  return [...known.values()];
}

/** Налаштування проєкту, якому належить цей каталог (з підкаталогами). */
function settingsFor(cwd) {
  if (!cwd) return {};

  let winner = null;
  for (const entry of known.values()) {
    const prefix = entry.path.endsWith('/') ? entry.path : entry.path + '/';
    if (cwd !== entry.path && !cwd.startsWith(prefix)) continue;
    if (!winner || entry.path.length > winner.path.length) winner = entry;
  }

  return winner?.settings || {};
}

function forget(cwd) {
  const existed = known.delete(cwd);
  if (existed) save();
  return existed;
}

load();

module.exports = { touch, list, forget, updateSettings, settingsFor, STORE_PATH };
