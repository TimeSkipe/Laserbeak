#!/bin/bash
# Місток між сесією (Claude Code або Codex) і фоновим демоном.
#
#   hook.sh <event> [agent]     # JSON хука читається зі stdin
#
# Навмисно тупий: жодної логіки, лише POST на localhost. Уся розумна
# частина — у демоні, тому сесія ніколи не чекає на osascript.
# Якщо демон лежить — мовчки виходимо з кодом 0, робота не постраждає.
#
# agent — чий це хук: claude (за замовчуванням) або codex. Його вписує
# сам запис у налаштуваннях хуків, тож тут нічого не вгадується.

exec 2>/dev/null

event="$1"
agent="${2:-claude}"
port="${LASERBEAK_PORT:-8787}"

# __CFBundleIdentifier ставить сама macOS: це bundle id програми, з якої
# запущено термінал. У WebStorm він дорівнює com.jetbrains.WebStorm, тоді
# як TERM_PROGRAM там порожній — тому саме ця змінна надійна.
#
# TMUX_PANE ставить tmux. Це адреса панелі (наприклад %3), у яку демон
# зможе написати ззовні через send-keys. Без tmux змінної немає — і
# написати в такий термінал неможливо: майстер його псевдотермінала
# тримає WebStorm, а ioctl TIOCSTI macOS прибрала.
curl -s -m 2 -X POST \
  -H 'Content-Type: application/json' \
  -H "X-Agent: ${agent}" \
  -H "X-Claude-Label: ${CLAUDE_LABEL:-}" \
  -H "X-Term-Program: ${TERM_PROGRAM:-}" \
  -H "X-App-Bundle: ${__CFBundleIdentifier:-}" \
  -H "X-Tmux-Pane: ${TMUX_PANE:-}" \
  -H "X-Hook-Ppid: $PPID" \
  --data-binary @- \
  "http://127.0.0.1:${port}/hook/${event}" >/dev/null

exit 0
