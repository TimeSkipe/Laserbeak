#!/bin/bash
# Прибирає laserbeak із системи. Дані в ~/.laserbeak лишаються.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
UID_NUM="$(id -u)"

echo "▸ зупиняю фонові процеси"
# Останні три — з часів, коли проєкт звався claude-notifyd.
for label in com.laserbeak.daemon com.laserbeak.app \
             com.claudenotify.daemon com.claudenotify.app com.claudenotify.menubar; do
  launchctl bootout "gui/$UID_NUM/$label" >/dev/null 2>&1 || true
  rm -f "$AGENTS/$label.plist"
done
echo "  ✓ агенти прибрано"

echo "▸ прибираю хуки з ~/.claude/settings.json"
node "$ROOT/scripts/patch-settings.js" --remove

echo "▸ прибираю хуки з ~/.codex/hooks.json"
node "$ROOT/scripts/patch-settings.js" --codex --remove

echo "▸ прибираю мод reply-cards"
CLAUDE_BIN="$(command -v claude || true)"
[ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$HOME/.local/bin/claude"
if [ -x "$CLAUDE_BIN" ]; then
  "$CLAUDE_BIN" plugin uninstall reply-cards@laserbeak >/dev/null 2>&1 || true
  "$CLAUDE_BIN" plugin marketplace remove laserbeak >/dev/null 2>&1 || true
fi

# Лише наш рядок і коментар над ним — решту ~/.zshrc не чіпаємо.
if grep -qF "$ROOT/shell/laserbeak.zsh" "$HOME/.zshrc" 2>/dev/null; then
  echo "▸ прибираю start / stop з ~/.zshrc"
  cp "$HOME/.zshrc" "$HOME/.laserbeak/zshrc.backup.$(date +%Y%m%d-%H%M%S)"
  grep -vF -e "$ROOT/shell/laserbeak.zsh" -e "# Laserbeak: start / stop" "$HOME/.zshrc" > "$HOME/.zshrc.laserbeak-tmp" \
    && mv "$HOME/.zshrc.laserbeak-tmp" "$HOME/.zshrc"
fi

for dir in /Applications "$HOME/Applications"; do
  for app in Laserbeak.app ClaudeNotify.app; do
    if [ -d "$dir/$app" ]; then
      rm -rf "$dir/$app"
      echo "▸ видалив $dir/$app"
    fi
  done
done

echo
echo "Готово. Дані лишились у ~/.laserbeak (config, логи, історія, копія .zshrc)."
