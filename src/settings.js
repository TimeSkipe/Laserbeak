'use strict';

// Загальні налаштування, які міняють із вікна програми: мова, які події
// показують банер, якими звуками і чи стежити за оновленнями.
//
// Живуть у config.json, поруч із рештою правил, тож їх можна правити й
// руками. Але з вікна пускаємо лише перелічене тут і лише допустимі
// значення: порт чи extensionId звідси не міняються, а записане читає
// демон на кожній події — невідомий звук чи мова там нікому не потрібні.

const fs = require('fs');
const config = require('./config');
const i18n = require('./i18n');

// Події, про які буває банер. Ті самі ключі в config.notify і config.sounds.
const KINDS = ['stop', 'permission', 'idle', 'update'];

const LANGUAGES = ['auto', ...i18n.LANGUAGES];

const GROUPS = ['language', 'notify', 'sounds', 'updates'];

const SOUNDS_DIR = '/System/Library/Sounds';

// Якщо теку раптом не прочитати — те, що в ній лежить на кожному маку.
const FALLBACK_SOUNDS = [
  'Basso', 'Blow', 'Bottle', 'Frog', 'Funk', 'Glass', 'Hero',
  'Morse', 'Ping', 'Pop', 'Purr', 'Sosumi', 'Submarine', 'Tink',
];

let sounds = null;

/** Системні звуки macOS — лише їх банер уміє програти за назвою. */
function availableSounds() {
  if (sounds) return sounds;

  try {
    sounds = fs.readdirSync(SOUNDS_DIR)
      .filter((f) => /\.(aiff?|caf|wav)$/i.test(f))
      .map((f) => f.replace(/\.[^.]+$/, ''))
      .sort();
  } catch {
    sounds = [];
  }

  if (!sounds.length) sounds = FALLBACK_SOUNDS;
  return sounds;
}

function get() {
  const cfg = config.get();

  return {
    settings: {
      language: cfg.language || 'auto',
      notify: Object.fromEntries(KINDS.map((k) => [k, cfg.notify?.[k] !== false])),
      sounds: Object.fromEntries(KINDS.map((k) => [k, cfg.sounds?.[k] || ''])),
      updates: { check: Boolean(cfg.updates?.check) },
    },
    // Якою мовою все говорить просто зараз — з урахуванням "auto".
    language: i18n.current(),
    languages: LANGUAGES,
    kinds: KINDS,
    sounds: availableSounds(),
  };
}

function invalid(key) {
  const err = i18n.said('err.badSetting', { key });
  err.code = 'EINVAL';
  return err;
}

/** З тіла запиту — у латку для config.json. Будь-що зайве відхиляємо. */
function patchFrom(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw invalid('body');

  const patch = {};

  for (const key of Object.keys(body)) {
    if (!GROUPS.includes(key)) throw invalid(key);
  }

  if ('language' in body) {
    if (!LANGUAGES.includes(body.language)) throw invalid('language');
    patch.language = body.language;
  }

  for (const group of ['notify', 'sounds']) {
    if (!(group in body)) continue;

    const values = body[group];
    if (!values || typeof values !== 'object' || Array.isArray(values)) throw invalid(group);

    for (const [kind, value] of Object.entries(values)) {
      const key = `${group}.${kind}`;
      if (!KINDS.includes(kind)) throw invalid(key);
      if (group === 'notify' && typeof value !== 'boolean') throw invalid(key);
      if (group === 'sounds' && value !== '' && !availableSounds().includes(value)) throw invalid(key);
      (patch[group] ||= {})[kind] = value;
    }
  }

  if ('updates' in body) {
    if (typeof body.updates?.check !== 'boolean') throw invalid('updates.check');
    patch.updates = { check: body.updates.check };
  }

  return patch;
}

/** Зберегти й повернути те, що вийшло. */
function save(body) {
  const patch = patchFrom(body);
  if (Object.keys(patch).length) config.update(patch);
  return { patch, ...get() };
}

module.exports = { get, save, availableSounds, KINDS };
