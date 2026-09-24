#!/bin/bash
# Запобіжник: не дати сесії Claude Code вбити сервер tmux.
#
# 31 серпня 2026 сесія в цьому проєкті двічі перевіряла функції start і
# stop із ~/.zshrc — і двічі закінчувала перевірку командою
# `tmux kill-server`. Разом із вигаданими сесіями гинули справжні: усі
# сесії Claude Code живуть в одному сервері tmux, тож смерть сервера
# закриває їх усі водночас. Подробиці — у docs/decisions.md.
#
# Спроба ізолювати тест через TMUX_TMPDIR від цього не рятує: шлях до
# сокета зі скретчпада виходить довшим за 104 байти (ліміт sun_path на
# macOS), і tmux мовчки бере типовий сокет, тобто справжній сервер.
#
# Тому kill-server дозволено лише разом із -L або -S — на явно названому
# сокеті. Це і є правильний спосіб тестувати.
#
# Вхід — JSON хука на stdin, вихід — рішення для PreToolUse.

payload=$(cat)

# Шукаємо в усьому запиті, а не лише в полі command: JSON з екранованими
# лапками розбирати нічим (jq на цій машині лежить у теці anaconda і в
# PATH хука може не потрапити), а для підрядка це й не потрібно.
case "$payload" in
  *kill-server*) ;;
  *) exit 0 ;;
esac

# Свій сокет — будь ласка: загине тільки він.
case "$payload" in
  *' -L '*|*' -S '*) exit 0 ;;
esac

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "tmux kill-server убиває сервер, у якому живуть УСІ сесії Claude Code — і твоя теж. Так уже двічі гинула робота (docs/decisions.md). Для тестів піднімай окремий сервер: tmux -L проба new-session ... , і гаси його як tmux -L проба kill-server."
  }
}
JSON
