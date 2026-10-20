#!/bin/bash
# Оновлення, запущене кнопкою в програмі (POST /update/install).
#
#   git pull --ff-only  →  scripts/install.sh
#
# Запускає його демон, відірваним від себе (setsid): install.sh по дорозі
# демон перезапускає, і скрипт мусить це пережити. Вивід іде в
# ~/.laserbeak/update.log, а що вийшло — у ~/.laserbeak/update-result.json.
# Його прочитає вже новий демон і скаже банером.
#
# Мова й решта налаштувань не губляться: install.sh бере їх із наявного
# config.json, якщо LASERBEAK_LANG не задано.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA="$HOME/.laserbeak"
RESULT="$DATA/update-result.json"
STEP="pull"

finish() {
  local code=$?
  local head
  head="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
  printf '{"code":%d,"step":"%s","head":"%s","at":%d}\n' \
    "$code" "$STEP" "$head" "$(date +%s)" > "$RESULT"
}
trap finish EXIT

echo
echo "════ $(date '+%F %T') · оновлення з $(git -C "$ROOT" rev-parse --short HEAD)"

# --ff-only: якщо тут є свої зміни, що розходяться з GitHub, краще
# зупинитись, ніж зливати чи переписувати чужу роботу мовчки.
git -C "$ROOT" pull --ff-only || exit 1

STEP="install"
bash "$ROOT/scripts/install.sh" || exit 1

STEP="done"
