#!/usr/bin/env node
'use strict';

// Обережно вписує наші хуки в налаштування агента:
//
//   patch-settings.js                  Claude Code → ~/.claude/settings.json
//   patch-settings.js --codex          Codex       → ~/.codex/hooks.json
//   ... --remove                       зняти наші хуки
//
// Правила безпеки:
//   • перед записом робиться бекап із таймстампом;
//   • усі інші ключі (statusLine, plugins, env, permissions) не чіпаються;
//   • чужі хуки зберігаються — видаляються лише наші попередні
//     (ті, що містять laserbeak у команді);
//   • --remove знімає наші хуки і нічого більше.
//
// Формат хуків у Codex той самий, що в Claude Code (перевірено на
// hooks.json його вбудованих плагінів), тож скрипт один. Відмінність —
// у назвах подій і в тому, що Codex не запустить нових хуків, доки
// людина не підтвердить їх у ньому самому. Обходити це не будемо.

const fs = require('fs');
const path = require('path');
const os = require('os');

const ROOT = path.resolve(__dirname, '..');
const HOOK = path.join(ROOT, 'hooks', 'hook.sh');
const MARKER = 'laserbeak';

const remove = process.argv.includes('--remove');
const codex = process.argv.includes('--codex');

// Подія агента -> наша назва події
const TARGETS = {
  claude: {
    file: path.join(os.homedir(), '.claude', 'settings.json'),
    agent: '',
    map: {
      SessionStart: 'session-start',
      UserPromptSubmit: 'prompt',
      Stop: 'stop',
      Notification: 'notification',
      SessionEnd: 'session-end',
    },
  },
  codex: {
    file: path.join(process.env.CODEX_HOME || path.join(os.homedir(), '.codex'), 'hooks.json'),
    agent: 'codex',
    map: {
      SessionStart: 'session-start',
      UserPromptSubmit: 'prompt',
      Stop: 'stop',
      // У Codex запит дозволу — окрема подія, без тексту, який довелось
      // би розпізнавати, як у Notification від Claude.
      PermissionRequest: 'approval',
      // Esc посеред ходу. Без неї сесія лишалась би «працює».
      Interrupt: 'interrupt',
      SessionEnd: 'session-end',
    },
  },
};

const target = TARGETS[codex ? 'codex' : 'claude'];

function isOurs(entry) {
  return JSON.stringify(entry).includes(MARKER);
}

function main() {
  let settings = {};
  if (fs.existsSync(target.file)) {
    const raw = fs.readFileSync(target.file, 'utf8');
    try {
      settings = JSON.parse(raw);
    } catch (e) {
      console.error(`✖ ${target.file} не є валідним JSON: ${e.message}`);
      console.error('  Виправ файл вручну і запусти ще раз — я нічого не чіпав.');
      process.exit(1);
    }
    const backup = `${target.file}.backup.${Date.now()}`;
    fs.writeFileSync(backup, raw);
    console.log(`  бекап: ${backup}`);
  } else if (remove) {
    console.log(`  ${target.file} немає — знімати нічого`);
    return;
  }

  const hooks = settings.hooks && typeof settings.hooks === 'object' ? { ...settings.hooks } : {};

  for (const agentEvent of Object.keys(target.map)) {
    // прибрати наші попередні записи, чужі лишити
    const kept = (hooks[agentEvent] || []).filter((g) => !isOurs(g));

    if (!remove) {
      const args = [target.map[agentEvent], target.agent].filter(Boolean).join(' ');
      kept.push({
        hooks: [{
          type: 'command',
          command: `bash '${HOOK}' ${args}`,
          timeout: 5,
        }],
      });
    }

    if (kept.length) hooks[agentEvent] = kept;
    else delete hooks[agentEvent];
  }

  if (Object.keys(hooks).length) settings.hooks = hooks;
  else delete settings.hooks;

  fs.mkdirSync(path.dirname(target.file), { recursive: true });
  fs.writeFileSync(target.file, JSON.stringify(settings, null, 2) + '\n');
  console.log(remove ? '  ✓ хуки laserbeak прибрано' : `  ✓ хуки прописано (${Object.keys(target.map).join(', ')})`);
}

main();
