#!/bin/bash
# Збирає macOS-застосунок і кладе його в теку програм.
#
# .xcodeproj не тримаємо в git — він щоразу генерується з app/project.yml,
# тому конфліктів у ньому не буває.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"

# Сертифікат беремо той, що є на цій машині: проєкт має збиратись у
# будь-кого, а не лише в автора.
TEAM="$(bash "$ROOT/scripts/team-id.sh")" || exit 1
echo "▸ підписую як команда $TEAM"

echo "▸ генерую Xcode-проєкт"
(cd "$ROOT/app" && xcodegen generate >/dev/null)

echo "▸ збираю Laserbeak.app"
xcodebuild \
  -project "$ROOT/app/Laserbeak.xcodeproj" \
  -scheme Laserbeak \
  -configuration Release \
  -derivedDataPath "$BUILD/dd" \
  LASERBEAK_TEAM="$TEAM" \
  build >/dev/null 2>&1 || {
    echo "  ✖ збірка впала. Деталі:"
    xcodebuild -project "$ROOT/app/Laserbeak.xcodeproj" -scheme Laserbeak \
      -configuration Release -derivedDataPath "$BUILD/dd" build 2>&1 | grep -E "error:" | head -20
    exit 1
  }

BUILT="$BUILD/dd/Build/Products/Release/Laserbeak.app"
[ -d "$BUILT" ] || { echo "  ✖ не знайшов $BUILT"; exit 1; }

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

# І одразу піднімаємо назад. Програма тримає єдиний канал до телефона,
# тож поки її немає, телефон сліпий. Демон помітив би тишу й підняв її
# сам, але аж за хвилину — після власної збірки чекати цього безглуздо.
#
# Аргументи ті самі, що й у LaunchAgent: -g щоб не лізти на передній
# план, --background щоб не відкривати вікно.
/usr/bin/open -g -a "$DEST/Laserbeak.app" --args --background

echo "  ✓ $DEST/Laserbeak.app"
