#!/bin/bash
# Збирає macOS-застосунок і кладе його в теку програм.
#
# .xcodeproj не тримаємо в git — він щоразу генерується з app/project.yml,
# тому конфліктів у ньому не буває.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"

. "$ROOT/scripts/lang.sh"

# Сертифікат беремо той, що є на цій машині: проєкт має збиратись у
# будь-кого, а не лише в автора.
TEAM="$(bash "$ROOT/scripts/team-id.sh")" || exit 1
say build.team "$TEAM"

say build.project
(cd "$ROOT/app" && xcodegen generate >/dev/null)

say build.app
xcodebuild \
  -project "$ROOT/app/Laserbeak.xcodeproj" \
  -scheme Laserbeak \
  -configuration Release \
  -derivedDataPath "$BUILD/dd" \
  LASERBEAK_TEAM="$TEAM" \
  build >/dev/null 2>&1 || {
    say build.failed
    xcodebuild -project "$ROOT/app/Laserbeak.xcodeproj" -scheme Laserbeak \
      -configuration Release -derivedDataPath "$BUILD/dd" build 2>&1 | grep -E "error:" | head -20
    exit 1
  }

BUILT="$BUILD/dd/Build/Products/Release/Laserbeak.app"
[ -d "$BUILT" ] || { say build.notFound "$BUILT"; exit 1; }

# /Applications зазвичай доступна адміну без sudo; якщо ні — беремо домашню.
DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi

# Програма може бути запущена — спершу гасимо, інакше отримаємо "Text file busy".
osascript -e 'tell application "Laserbeak" to quit' >/dev/null 2>&1 || true
sleep 0.5

rm -rf "$DEST/Laserbeak.app"
cp -R "$BUILT" "$DEST/"

echo "$DEST/Laserbeak.app" > "$BUILD/app-path.txt"

# І одразу піднімаємо назад. Програма — це меню-бар і банери з іконкою
# проєкту; поки її немає, банери йдуть безликим terminal-notifier. Демон
# помітив би тишу й підняв її сам, але аж за хвилину — після власної
# збірки чекати цього безглуздо.
#
# Аргументи ті самі, що й у LaunchAgent: -g щоб не лізти на передній
# план, --background щоб не відкривати вікно.
/usr/bin/open -g -a "$DEST/Laserbeak.app" --args --background

echo "  ✓ $DEST/Laserbeak.app"
