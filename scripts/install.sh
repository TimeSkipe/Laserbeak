#!/bin/bash
# Повна установка laserbeak. Ідемпотентна — можна ганяти скільки завгодно.
#
#   bash scripts/install.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$HOME/.laserbeak"
AGENTS="$HOME/Library/LaunchAgents"
UID_NUM="$(id -u)"

# Тексти — п'ятьма мовами, з однієї таблиці (scripts/lang.sh).
. "$ROOT/scripts/lang.sh"

echo "╭─ laserbeak"
echo "│  $(lb_t install.code): $ROOT"
echo "│  $(lb_t install.data): $DATA"
echo "╰─"
echo

mkdir -p "$DATA" "$AGENTS" "$ROOT/build"


# ---------------------------------------------------------------- 0. мова
#
# Одна мова на все: банери, історія, вікно програми, розширення браузера.
# Живе в config.json; програма й розширення беруть її в демона.
#
#   LASERBEAK_LANG=cs npm run install:all   явно
#   (нічого, перша установка)               як у системі
#   (нічого, перевстановлення чи оновлення) та, що вже вибрана
#
# Останнє важливе: оновлення — це git pull і цей самий скрипт, і
# скидати вибрану мову на "auto" щоразу було б підступно.

CURRENT_LANG="$(node -e "try{console.log(JSON.parse(require('fs').readFileSync('$DATA/config.json','utf8')).language||'')}catch(e){console.log('')}" 2>/dev/null || true)"
LANG_CHOICE="${LASERBEAK_LANG:-${CURRENT_LANG:-auto}}"
case "$LANG_CHOICE" in
  uk|en|cs|ru|kk|auto) ;;
  *) say install.langUnknown "$LANG_CHOICE"; LANG_CHOICE="auto" ;;
esac

# Далі говоримо вже вибраною мовою — і дочірні скрипти теж: build-app,
# team-id і patch-settings беруть її з LB_LANG.
if [ "$LANG_CHOICE" = "auto" ]; then LB_LANG="$(lb_system_lang)"; else LB_LANG="$LANG_CHOICE"; fi
export LB_LANG
say install.lang "$LANG_CHOICE"

# У конфіг — одразу, до збірки: програма підніметься наприкінці збірки і
# має застати вже правильну мову.
node -e "
const fs = require('fs'), p = '$DATA/config.json';
let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(p, 'utf8')); } catch {}
cfg.language = '$LANG_CHOICE';
fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + '\\n');
"

# Вікно програми бере мову з того самого конфіга при кожному запуску
# (Language.swift). Але macOS вирішує, якою мовою малювати, ще до
# першого рядка нашого коду, — тож перший запуск після установки мусить
# застати вибір уже в налаштуваннях програми.
if [ "$LANG_CHOICE" = "auto" ]; then
  defaults delete com.laserbeak.desktop AppleLanguages >/dev/null 2>&1 || true
else
  defaults write com.laserbeak.desktop AppleLanguages -array "$LANG_CHOICE"
fi

# ---------------------------------------------------------------- 1. залежності

NODE="$(command -v node || true)"
[ -n "$NODE" ] || { say install.noNode; exit 1; }
echo "▸ node: $NODE ($(node -v))"

command -v xcodegen >/dev/null || { say install.noXcodegen; exit 1; }

# Без tmux програма працює, але писати в сесії WebStorm неможливо —
# половина сенсу зникає мовчки, і здогадатись про причину важко.
if ! command -v tmux >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    say install.tmuxInstall
    brew install tmux
  else
    say install.tmuxMissing
    say install.tmuxHow
  fi
else
  echo "▸ tmux: $(command -v tmux)"
fi

if ! command -v terminal-notifier >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    say install.notifierInstall
    brew install terminal-notifier
  else
    say install.notifierMissing
  fi
else
  echo "▸ terminal-notifier: $(command -v terminal-notifier)"
fi

# ---------------------------------------------------------------- 2. застосунок

bash "$ROOT/scripts/build-app.sh"
APP_PATH="$(cat "$ROOT/build/app-path.txt")"

# ---------------------------------------------------------------- 3. launchd

say install.agents

# Агенти з часів, коли проєкт звався claude-notifyd
for old in com.claudenotify.daemon com.claudenotify.app com.claudenotify.menubar; do
  launchctl bootout "gui/$UID_NUM/$old" >/dev/null 2>&1 || true
  rm -f "$AGENTS/$old.plist"
done

for name in daemon app; do
  label="com.laserbeak.$name"
  plist="$AGENTS/$label.plist"

  sed -e "s|__ROOT__|$ROOT|g" \
      -e "s|__DATA__|$DATA|g" \
      -e "s|__NODE__|$NODE|g" \
      -e "s|__APP__|$APP_PATH|g" \
      "$ROOT/launchd/$label.plist.template" > "$plist"

  # bootout працює асинхронно: якщо одразу викликати bootstrap, launchd
  # відповість "Input/output error". Чекаємо, доки служба справді зникне.
  launchctl bootout "gui/$UID_NUM/$label" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "gui/$UID_NUM/$label" >/dev/null 2>&1 || break
    sleep 0.5
  done

  launchctl bootstrap "gui/$UID_NUM" "$plist"
  launchctl enable "gui/$UID_NUM/$label" >/dev/null 2>&1 || true
  echo "  ✓ $label"
done


# ---------------------------------------------------------------- 4. хуки

say install.hooksClaude
chmod +x "$ROOT/hooks/hook.sh"
node "$ROOT/scripts/patch-settings.js"

# Codex — якщо він є: окремо в PATH або вбудований у ChatGPT.app. Нових
# хуків він не запустить, доки їх не підтвердять у ньому самому, — тож
# на першому `start codex` Codex попросить їх переглянути.
if command -v codex >/dev/null 2>&1 || [ -x /Applications/ChatGPT.app/Contents/Resources/codex ]; then
  say install.hooksCodex
  node "$ROOT/scripts/patch-settings.js" --codex
  say install.codexTrust
fi

# ---------------------------------------------------------------- 5. швидкі команди
#
# start і stop — без них сесію не запустити через tmux, а отже Laserbeak
# не зможе передати в неї ні скріншот, ні режим. Їх легко забути, тому
# ставимо самі: один рядок source у ~/.zshrc. Сам код живе в репозиторії
# (shell/laserbeak.zsh) і оновлюється разом із ним.
#
# Свою стару копію start() у ~/.zshrc не чіпаємо — це файл людини. Лише
# кажемо, що її варто замінити цим рядком.

say install.commands
ZSHRC="$HOME/.zshrc"
SOURCE_LINE="source \"$ROOT/shell/laserbeak.zsh\""

if grep -qF "$ROOT/shell/laserbeak.zsh" "$ZSHRC" 2>/dev/null; then
  say install.commandsHave
elif grep -qE '^[[:space:]]*(function[[:space:]]+)?start[[:space:]]*\(\)' "$ZSHRC" 2>/dev/null; then
  say install.commandsOwn
  say install.commandsReplace
  echo "      $SOURCE_LINE"
else
  # Коментар англійською: він лягає в чужий ~/.zshrc, а uninstall.sh
  # знаходить його за префіксом «# Laserbeak: start / stop».
  printf '\n# Laserbeak: start / stop (Claude Code and Codex sessions in tmux)\n%s\n' \
    "$SOURCE_LINE" >> "$ZSHRC"
  say install.commandsAdded
fi

case "${SHELL:-}" in
  */zsh) ;;
  *) say install.notZsh "${SHELL:-?}" ;;
esac

# ---------------------------------------------------------------- 6. картки відповідей
#
# Мод Claude Code, що малює відповіді нумерованими картками (що зроблено,
# важливо знати, питання) і сам додає це правило в системний промпт.
# Репозиторій — маркетплейс із теки (.claude-plugin/marketplace.json), тож
# мод читається прямо звідси: git pull оновлює і його.

CLAUDE_BIN="$(command -v claude || true)"
[ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$HOME/.local/bin/claude"

say install.cards
if [ -x "$CLAUDE_BIN" ]; then
  "$CLAUDE_BIN" plugin marketplace add "$ROOT" >/dev/null 2>&1 || true
  if "$CLAUDE_BIN" plugin install reply-cards@laserbeak --scope user >/dev/null 2>&1; then
    say install.cardsOn
  else
    say install.cardsFailed
  fi
else
  say install.cardsNoClaude
fi

# ---------------------------------------------------------------- 7. перевірка

say install.check
sleep 2

PORT="$(node -e "try{console.log(JSON.parse(require('fs').readFileSync('$DATA/config.json','utf8')).port||8787)}catch(e){console.log(8787)}")"

if curl -s -m 3 "http://127.0.0.1:$PORT/health" | grep -q '"ok":true'; then
  say install.daemonOk "$PORT"
else
  say install.daemonDown "$DATA/daemon.log"
  exit 1
fi


echo
say install.ext
echo
say install.extWhat
say install.extManual
say install.extWhere
echo
say install.extStep1
say install.extStep1b
say install.extStep2
say install.extStep3 "$ROOT/extension"
echo
say install.extThen

echo
say install.done
say install.doneApp "$APP_PATH"
say install.doneRules "$DATA/config.json"
say install.doneLog "$DATA/daemon.log"
say install.doneErrors "$DATA/errors.log"
echo
say install.doneHooks
