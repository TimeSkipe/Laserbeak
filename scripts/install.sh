#!/bin/bash
# Повна установка laserbeak. Ідемпотентна — можна ганяти скільки завгодно.
#
#   bash scripts/install.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$HOME/.laserbeak"
AGENTS="$HOME/Library/LaunchAgents"
UID_NUM="$(id -u)"

echo "╭─ laserbeak"
echo "│  код:  $ROOT"
echo "│  дані: $DATA"
echo "╰─"
echo

mkdir -p "$DATA" "$AGENTS" "$ROOT/build"


# ---------------------------------------------------------------- 0. мова
#
# Мовою банерів і помилок керує Laserbeak, а не програма: банер складає
# він сам, і в запасному шляху через terminal-notifier ніякої програми
# взагалі немає.
#
#   LASERBEAK_LANG=cs npm run install:all   явно
#   (нічого)                                як у системі

LANG_CHOICE="${LASERBEAK_LANG:-auto}"
case "$LANG_CHOICE" in
  uk|en|cs|auto) ;;
  *) echo "  ⚠ мова «$LANG_CHOICE» невідома — беру auto"; LANG_CHOICE="auto" ;;
esac
echo "▸ мова повідомлень: $LANG_CHOICE"

# ---------------------------------------------------------------- 1. залежності

NODE="$(command -v node || true)"
[ -n "$NODE" ] || { echo "✖ node не знайдено"; exit 1; }
echo "▸ node: $NODE ($(node -v))"

command -v xcodegen >/dev/null || { echo "✖ xcodegen не знайдено: brew install xcodegen"; exit 1; }

# Без tmux програма працює, але писати в сесії WebStorm неможливо —
# половина сенсу зникає мовчки, і здогадатись про причину важко.
if ! command -v tmux >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "▸ ставлю tmux (без нього не можна писати в сесії)"
    brew install tmux
  else
    echo "  ⚠ tmux немає — запити з програми й телефона не працюватимуть."
    echo "    Постав його: brew install tmux"
  fi
else
  echo "▸ tmux: $(command -v tmux)"
fi

if ! command -v terminal-notifier >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "▸ ставлю terminal-notifier"
    brew install terminal-notifier
  else
    echo "  ⚠ terminal-notifier немає — банери підуть через osascript"
  fi
else
  echo "▸ terminal-notifier: $(command -v terminal-notifier)"
fi

# ---------------------------------------------------------------- 2. застосунок

bash "$ROOT/scripts/build-app.sh"
APP_PATH="$(cat "$ROOT/build/app-path.txt")"

# ---------------------------------------------------------------- 3. launchd

echo "▸ реєструю фонові процеси"

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
      -e "s|__LANG__|$LANG_CHOICE|g" \
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


# Мову кладемо в конфіг: LASERBEAK_LANG у launchd передається теж, але
# конфіг переживає перевстановлення й читається на льоту.
node -e "
const fs = require('fs'), p = '$DATA/config.json';
let cfg = {};
try { cfg = JSON.parse(fs.readFileSync(p, 'utf8')); } catch {}
cfg.language = '$LANG_CHOICE';
fs.mkdirSync('$DATA', { recursive: true });
fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + '\n');
"

# ---------------------------------------------------------------- 4. хуки

echo "▸ підключаю хуки Claude Code"
chmod +x "$ROOT/hooks/hook.sh"
node "$ROOT/scripts/patch-settings.js"

# Codex — якщо він є: окремо в PATH або вбудований у ChatGPT.app. Нових
# хуків він не запустить, доки їх не підтвердять у ньому самому, — тож
# на першому `start codex` Codex попросить їх переглянути.
if command -v codex >/dev/null 2>&1 || [ -x /Applications/ChatGPT.app/Contents/Resources/codex ]; then
  echo "▸ підключаю хуки Codex"
  node "$ROOT/scripts/patch-settings.js" --codex
  echo "  Codex попросить підтвердити ці хуки при першому запуску — це нормально."
fi

# ---------------------------------------------------------------- 5. перевірка

echo "▸ перевіряю"
sleep 2

PORT="$(node -e "try{console.log(JSON.parse(require('fs').readFileSync('$DATA/config.json','utf8')).port||8787)}catch(e){console.log(8787)}")"

if curl -s -m 3 "http://127.0.0.1:$PORT/health" | grep -q '"ok":true'; then
  echo "  ✓ демон живий на порті $PORT"
else
  echo "  ✖ демон не відповідає. Дивись $DATA/daemon.log"
  exit 1
fi

# Конфіг, створений до появи ключа доступу, лишився з відкритим портом.
# Мовчки його не міняємо — це файл користувача, — але сказати варто.
BIND="$(node -e "try{console.log(JSON.parse(require('fs').readFileSync('$DATA/config.json','utf8')).bindHost||'')}catch(e){console.log('')}")"
if [ "$BIND" = "0.0.0.0" ]; then
  echo
  echo "  ⚠ у конфігу bindHost = 0.0.0.0 — демон видно в локальній мережі."
  echo "    Це запасний шлях для телефона: працює й із закритою програмою,"
  echo "    але трафік відкритий (захищений лише ключем)."
  echo "    Замкнути повністю: постав \"bindHost\": \"127.0.0.1\" у"
  echo "    $DATA/config.json — телефон працюватиме прямим каналом."
fi


echo
echo "▸ розширення для браузера (необов'язкове)"
echo
echo "  Дає обвести зону на сторінці й надіслати її в сесію картинкою."
echo "  Ставиться руками — це три кліки, бо в Web Store його немає."
echo "  Клади в той браузер, яким керує сесія (там, де стоїть Claude in Chrome):"
echo
echo "    1. chrome://extensions (у Brave — brave://extensions)"
echo "       →  увімкни «Режим розробника»"
echo "    2. «Завантажити розпаковане»"
echo "    3. вкажи теку:  $ROOT/extension"
echo
echo "  Далі — ⌘⇧E на будь-якій сторінці."

echo
echo "Готово."
echo "  • Програма:  $APP_PATH"
echo "  • Правила:   $DATA/config.json  (перечитується на льоту)"
echo "  • Лог:       $DATA/daemon.log"
echo
echo "Хуки почнуть діяти в НОВИХ сесіях Claude Code — перезапусти сесію."
