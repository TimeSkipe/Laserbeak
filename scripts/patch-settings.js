#!/usr/bin/env node
'use strict';

// Обережно вписує наші хуки в ~/.claude/settings.json.
//
// Правила безпеки:
//   • перед записом робиться бекап із таймстампом;
//   • усі інші ключі (statusLine, plugins, env, permissions) не чіпаються;
//   • чужі хуки зберігаються — видаляються лише наші попередні
//     (ті, що містять laserbeak у команді);
//   • --remove знімає наші хуки і нічого більше.

const fs = require('fs');
const path = require('path');
const os = require('os');

const SETTINGS = path.join(os.homedir(), '.claude', 'settings.json');
const ROOT = path.resolve(__dirname, '..');
const HOOK = path.join(ROOT, 'hooks', 'hook.sh');
const MARKER = 'laserbeak';

const remove = process.argv.includes('--remove');

// Подія Claude Code -> наша назва події
const MAP = {
  SessionStart: 'session-start',
  UserPromptSubmit: 'prompt',
  Stop: 'stop',
  Notification: 'notification',
  SessionEnd: 'session-end',
};

function isOurs(entry) {
  return JSON.stringify(entry).includes(MARKER);
}

function main() {
  let settings = {};
  if (fs.existsSync(SETTINGS)) {
    const raw = fs.readFileSync(SETTINGS, 'utf8');
    try {
      settings = JSON.parse(raw);
    } catch (e) {
      console.error(`✖ ${SETTINGS} не є валідним JSON: ${e.message}`);
      console.error('  Виправ файл вручну і запусти ще раз — я нічого не чіпав.');
      process.exit(1);
    }
    const backup = `${SETTINGS}.backup.${Date.now()}`;
    fs.writeFileSync(backup, raw);
    console.log(`  бекап: ${backup}`);
  }

  const hooks = settings.hooks && typeof settings.hooks === 'object' ? { ...settings.hooks } : {};

  for (const claudeEvent of Object.keys(MAP)) {
    // прибрати наші попередні записи, чужі лишити
    const kept = (hooks[claudeEvent] || []).filter((g) => !isOurs(g));

    if (!remove) {
      kept.push({
        hooks: [{
          type: 'command',
          command: `bash '${HOOK}' ${MAP[claudeEvent]}`,
          timeout: 5,
        }],
      });
    }

    if (kept.length) hooks[claudeEvent] = kept;
    else delete hooks[claudeEvent];
  }

  if (Object.keys(hooks).length) settings.hooks = hooks;
  else delete settings.hooks;

  fs.writeFileSync(SETTINGS, JSON.stringify(settings, null, 2) + '\n');
  console.log(remove ? '  ✓ хуки laserbeak прибрано' : `  ✓ хуки прописано (${Object.keys(MAP).join(', ')})`);
}

main();
