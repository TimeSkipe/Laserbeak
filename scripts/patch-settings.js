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
//   • усі інші ключі (plugins, env, permissions) не чіпаються;
//   • чужі хуки зберігаються — видаляються лише наші попередні
//     (ті, що містять laserbeak у команді);
//   • statusLine Claude Code обгортається hooks/statusline.sh: ліміти
//     підписки є лише там (src/limits.js). Твоя команда переїжджає в
//     ~/.laserbeak/statusline-command і малює рядок, як і раніше;
//   • --remove знімає наші хуки й повертає твій statusLine — і нічого більше.
//
// Формат хуків у Codex той самий, що в Claude Code (перевірено на
// hooks.json його вбудованих плагінів), тож скрипт один. Відмінність —
// у назвах подій і в тому, що Codex не запустить нових хуків, доки
// людина не підтвердить їх у ньому самому. Обходити це не будемо.

const fs = require('fs');
const path = require('path');
const os = require('os');
const { t } = require('./lang');

const ROOT = path.resolve(__dirname, '..');
const HOOK = path.join(ROOT, 'hooks', 'hook.sh');
const STATUSLINE = path.join(ROOT, 'hooks', 'statusline.sh');
const DATA_DIR = process.env.LASERBEAK_DIR || path.join(os.homedir(), '.laserbeak');
// Твоя команда рядка стану, поки її місце займає наша обгортка.
const STATUSLINE_COMMAND = path.join(DATA_DIR, 'statusline-command');
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
      // Запит дозволу — щойно зʼявився діалог. Notification про нього ж
      // приходить на шість секунд пізніше й лишається запасним шляхом: для
      // старіших версій Claude Code і діалогів, де PermissionRequest
      // раптом не спрацює.
      PermissionRequest: 'approval',
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

// Рядок стану — єдине місце, куди Claude Code віддає ліміти підписки.
// Обгортка шле їх демону, а рядок малює твоя команда.
function patchStatusLine(settings) {
  const current = settings.statusLine;
  const ours = Boolean(current) && isOurs(current);

  if (remove) {
    if (!ours) return;
    let saved = '';
    try {
      saved = fs.readFileSync(STATUSLINE_COMMAND, 'utf8').trim();
    } catch {
      // файлу немає — до нас рядка стану не було
    }
    if (saved) settings.statusLine = { ...current, type: 'command', command: saved };
    else delete settings.statusLine;
    fs.rmSync(STATUSLINE_COMMAND, { force: true });
    return;
  }

  // Уже обгорнуто — лише оновлюємо шлях (репозиторій могли перенести), а
  // збережену команду не чіпаємо: інакше там опинилась би наша ж обгортка.
  if (!ours) {
    const command = current?.type === 'command' && typeof current.command === 'string' ? current.command : '';
    fs.mkdirSync(DATA_DIR, { recursive: true });
    fs.writeFileSync(STATUSLINE_COMMAND, command ? `${command}\n` : '');
  }
  settings.statusLine = { ...(current || {}), type: 'command', command: `bash '${STATUSLINE}'` };
  console.log(t('patch.statusline', STATUSLINE_COMMAND));
}

function main() {
  let settings = {};
  if (fs.existsSync(target.file)) {
    const raw = fs.readFileSync(target.file, 'utf8');
    try {
      settings = JSON.parse(raw);
    } catch (e) {
      console.error(t('patch.badJson', target.file, e.message));
      console.error(t('patch.fixManually'));
      process.exit(1);
    }
    const backup = `${target.file}.backup.${Date.now()}`;
    fs.writeFileSync(backup, raw);
    console.log(t('patch.backup', backup));
  } else if (remove) {
    console.log(t('patch.nothing', target.file));
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

  // Рядок стану з лімітами є лише в Claude Code.
  if (!codex) patchStatusLine(settings);

  fs.mkdirSync(path.dirname(target.file), { recursive: true });
  fs.writeFileSync(target.file, JSON.stringify(settings, null, 2) + '\n');
  console.log(remove ? t('patch.removed') : t('patch.added', Object.keys(target.map).join(', ')));
}

main();
