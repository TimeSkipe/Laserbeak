#!/bin/bash
# Рядок стану Claude Code, пропущений через Laserbeak.
#
#   statusLine.command = bash statusline.sh    # JSON рядка стану — у stdin
#
# Ліміти підписки (5-годинний і тижневий: відсоток і час скидання) Claude
# Code віддає лише рядку стану — на диску їх немає. Тож цей скрипт стоїть
# у statusLine замість твоєї команди: копію вводу шле демону, а сам рядок
# малює твоя команда, як і раніше. Вона лежить у ~/.laserbeak/statusline-command
# — туди її поклав scripts/patch-settings.js, і він же поверне її на місце.
#
# Тупий, як hook.sh: curl іде фоном і рядок стану на нього не чекає; демон
# лежить — нічого не стається.

input=$(cat)
port="${LASERBEAK_PORT:-8787}"

printf '%s' "$input" | curl -s -m 1 -X POST \
  -H 'Content-Type: application/json' \
  --data-binary @- \
  "http://127.0.0.1:${port}/limits/claude" >/dev/null 2>&1 &

command_file="${LASERBEAK_DIR:-$HOME/.laserbeak}/statusline-command"
[ -s "$command_file" ] || exit 0
printf '%s' "$input" | bash -c "$(cat "$command_file")"
