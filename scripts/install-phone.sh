#!/bin/bash
# Збирає застосунок і ставить його на підключений iPhone.
#
#   bash scripts/install-phone.sh
#
# Потрібно один раз: платформа iOS у Xcode
#   xcodebuild -downloadPlatform iOS
#
# Без неї пристрій видно як "connected (no DDI)", і збірка падає з
# "iOS 26.5 is not installed".

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build/dd-phone"

echo "▸ шукаю підключений пристрій"

DEVICE_JSON="$(mktemp)"
xcrun devicectl list devices --json-output "$DEVICE_JSON" >/dev/null 2>&1 || true

# Потрібен саме апаратний UDID: devicectl показує ще й свій внутрішній
# ідентифікатор, але xcodebuild розуміє лише UDID.
UDID="$(/usr/bin/python3 - "$DEVICE_JSON" <<'PY_INNER'
import json, sys

try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)

candidates = []

for device in data.get("result", {}).get("devices", []):
    hardware = device.get("hardwareProperties", {})
    if hardware.get("platform") != "iOS":
        continue

    udid = hardware.get("udid")
    if not udid:
        continue

    connection = device.get("connectionProperties", {})

    # Активний тунель — найкращий кандидат. Далі за свіжістю звʼязку:
    # у списку лежать і давно забуті пристрої, і саме тому раніше
    # вибирався старий телефон замість підключеного.
    live = connection.get("tunnelState") not in ("unavailable", "disconnected")
    seen = connection.get("lastConnectionDate", "")

    candidates.append((1 if live else 0, seen, udid))

if candidates:
    candidates.sort(reverse=True)
    print(candidates[0][2])
PY_INNER
)"
rm -f "$DEVICE_JSON"

if [ -z "$UDID" ]; then
  echo "  ✖ пристрій не знайдено"
  echo "    Підключи iPhone кабелем, розблокуй його і дозволь довіру до цього компʼютера."
  exit 1
fi

echo "  ✓ пристрій: $UDID"

TEAM="$(bash "$ROOT/scripts/team-id.sh")" || exit 1
echo "▸ підписую як команда $TEAM"

echo "▸ генерую Xcode-проєкт"
(cd "$ROOT/app" && xcodegen generate >/dev/null)

echo "▸ збираю (перший раз може попросити дозвіл на підпис)"
xcodebuild \
  -project "$ROOT/app/Laserbeak.xcodeproj" \
  -scheme LaserbeakPhone \
  -configuration Release \
  -destination "id=$UDID" \
  -derivedDataPath "$BUILD" \
  -allowProvisioningUpdates \
  LASERBEAK_TEAM="$TEAM" \
  build >/dev/null 2>&1 || {
    echo "  ✖ збірка впала. Деталі:"

    if xcodebuild -project "$ROOT/app/Laserbeak.xcodeproj" -scheme LaserbeakPhone \
         -configuration Release -destination "id=$UDID" -derivedDataPath "$BUILD" \
         -allowProvisioningUpdates LASERBEAK_TEAM="$TEAM" build 2>&1 | grep -q "Developer Mode disabled"; then
      echo
      echo "    На телефоні вимкнено режим розробника."
      echo "    Параметри → Конфіденційність і безпека → Режим розробника → увімкнути."
      echo "    Телефон перезавантажиться і спитає підтвердження."
      exit 1
    fi

    xcodebuild -project "$ROOT/app/Laserbeak.xcodeproj" -scheme LaserbeakPhone \
      -configuration Release -destination "id=$UDID" -derivedDataPath "$BUILD" \
      -allowProvisioningUpdates LASERBEAK_TEAM="$TEAM" build 2>&1 | grep -E "error:" | head -15
    exit 1
  }

APP="$BUILD/Build/Products/Release-iphoneos/Laserbeak.app"
[ -d "$APP" ] || { echo "  ✖ не знайшов $APP"; exit 1; }

echo "▸ ставлю на пристрій"
xcrun devicectl device install app --device "$UDID" "$APP" >/dev/null

echo
echo "Готово. Laserbeak на телефоні."
echo
echo "При першому запуску:"
echo "  • дозволь доступ до локальної мережі — без нього Bonjour мовчатиме;"
echo "  • якщо iOS не довіряє розробнику: Параметри → Основні →"
echo "    VPN і керування пристроєм → довірити."
echo
echo "Телефон і ноут мають бути в одному Wi-Fi."
