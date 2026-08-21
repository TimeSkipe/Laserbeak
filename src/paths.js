'use strict';

// Єдине місце, де живуть шляхи. Код — у репозиторії, дані користувача —
// у ~/.laserbeak, щоб проєкт можна було клонувати куди завгодно.

const os = require('os');
const path = require('path');
const fs = require('fs');

const HOME = os.homedir();
const PROJECT_DIR = path.resolve(__dirname, '..');
const DATA_DIR = process.env.LASERBEAK_DIR || path.join(HOME, '.laserbeak');

// Дані зі старої назви (claude-notifyd) переїжджають самі — один раз.
const LEGACY_DIR = path.join(HOME, '.claude', 'notifyd');
if (!fs.existsSync(DATA_DIR) && fs.existsSync(LEGACY_DIR)) {
  try {
    fs.renameSync(LEGACY_DIR, DATA_DIR);
  } catch {
    // не вийшло — просто почнемо з чистого
  }
}

fs.mkdirSync(DATA_DIR, { recursive: true });

module.exports = {
  HOME,
  PROJECT_DIR,
  DATA_DIR,
  CONFIG_PATH: path.join(DATA_DIR, 'config.json'),
  EVENTS_PATH: path.join(DATA_DIR, 'events.jsonl'),
  SHOTS_DIR: path.join(DATA_DIR, 'shots'),
  LOG_PATH: path.join(DATA_DIR, 'daemon.log'),
  HOOK_SCRIPT: path.join(PROJECT_DIR, 'hooks', 'hook.sh'),
};
