# Components

## Daemon — `src/`

### Core

| File | Responsibility |
|------|----------------|
| `daemon.js` | entry point; listens on `127.0.0.1`, starts two timers (transcript ingestion 2 s, session liveness 30 s), the app guard and the update check |
| `server.js` | HTTP API; the two entrance checks (from this computer, not from a web page) |
| `state.js` | memory: live sessions, history, per-project rollups; `snapshot()` assembles everything for `/state` |
| `events.js` | hook event handling — the only place where user actions mutate state |
| `config.js` | config from `~/.laserbeak/config.json`, re-read on the fly; `update()` writes a change into the file without touching the rest |
| `settings.js` | what the window may change in the config — language, banners, sounds, update checks — and with which values |
| `paths.js` | every path in one place; the migration from the old name lives here too |
| `log.js` | logs to stdout, which launchd writes to `daemon.log` — one record per line, local time; warnings and errors also go to `errors.log` with code, stderr and stack; `warnRepeated`/`errorRepeated` for errors that would repeat on a timer; rotates both files |
| `i18n.js` | user-visible text in uk/en/cs/ru/kk; resolves `auto`; logs stay in one language on purpose |

### Watching

| File | Responsibility |
|------|----------------|
| `inspect.js` | process inspection: terminal tabs, live `claude` processes, projects open in an IDE |
| `procs.js` | linking a session to its process: searching up and down the tree for `claude` |
| `roots.js` | which directory counts as the project (IDE → `.git` → the directory itself) |
| `modes.js` | reading the permission mode from the Claude Code status line, effort from `~/.claude/settings.json` |
| `reaper.js` | collecting sessions that are no longer alive |
| `appguard.js` | keeps the Mac app alive: it is the menu bar and the banners |
| `updates.js` | is there a newer version on GitHub, and the commands that install it |

### Actions

| File | Responsibility |
|------|----------------|
| `input.js` | where to write into a session: own terminal or tmux pane |
| `tmux.js` | input into WebStorm sessions: `send-keys`, Shift+Tab, `capture-pane` |
| `terminals.js` | sessions the daemon started in its own pseudo-terminal (API only, the app no longer offers it) |
| `pty-bridge.py` | the pseudo-terminal itself; standard library only |
| `notify.js` | notifications: through the app, or via `terminal-notifier` as fallback; `announce()` for ones that are not about a session |
| `shots.js` | region screenshots from the browser: save the file, assemble the prompt in the chosen language, sweep old ones |
| `outbox.js` | notification queue for the Mac app (long-poll) |

### Storage

| File | Responsibility |
|------|----------------|
| `projects.js` | project registry: names, editor, colour and icon |
| `sessionSettings.js` | custom session names and notification switches |
| `archive.js` | conversation archive and `lastBrowserUse`; distillation, deduplication, incremental reads |

## The Mac app — `app/`

The Xcode project is generated from `app/project.yml` with `xcodegen`;
the `.xcodeproj` itself is not kept in git. One target, macOS 14+.

| File | What it is |
|------|------------|
| `LaserbeakApp.swift` | entry point; agent app (no Dock icon), one window + menu bar; `AppRouter` opens the window on a given section from anywhere |
| `MainWindow.swift` | the window: sidebar (Sessions, Activity, Settings: General / Notifications / Updates) and the selected pane |
| `SessionsPane.swift` | projects as cards, sessions as rows: status, mode, the actions menu (details, name, model, effort, compact, interrupt, remove) |
| `ActivityPane.swift` | event history by day |
| `SettingsPanes.swift` | General (language, about), Notifications (per event: on/off and sound), Updates (status, what is new, how to install) |
| `Views.swift` | sheets: session details, session name and notifications, project colour and icon; the empty state |
| `Theme.swift` | cards, status pills, icon tiles, the pulsing status badge |
| `MenuBar.swift` | the menu bar icon and menu |
| `Notifications.swift` | banners from the app itself: project icon with the event badge, its own log file |
| `Language.swift` | the window's language: from `config.json` into `AppleLanguages`, relaunch |
| `Models.swift` | mirror of the JSON from `/state`, `/settings`, `/update`; **hand-written decoding**, see below |
| `DaemonClient.swift` | polling `/state` and every action |
| `Transport.swift` | plain HTTP to `127.0.0.1` |
| `Palette.swift` | project colours |
| `LucideIcons.swift` | **generated** file — do not edit by hand |
| `Resources/Localizable.xcstrings` | String Catalog: every string × uk/en/cs/ru/kk |

### How to add a field to a model

Swift does **not** substitute a default for a missing key. That is why
every model has its own `init(from:)`. When adding a field:

```swift
var newField: Int = 0                       // 1. the property

enum CodingKeys: String, CodingKey {
    case /* ... */, newField                // 2. the key
}

init(from decoder: Decoder) throws {
    // ...
    newField = c.value(.newField, 0)        // 3. decoding with a fallback
}
```

Miss a step and the app shows a blank screen, because decoding of the
*entire* response fails, not just that one field.

### How to add a string to the interface

Write it in Ukrainian in the code (`Text("…")`, `String(localized: "…")`)
and add it to `Localizable.xcstrings` with all five languages — the build
does **not** do this for `String(localized:)`. Then:

```bash
npm run check:l10n
```

It finds every string in the code and fails on anything missing in any
language, in the app, the extension, the daemon and `start`/`stop`.

## Browser extension — `extension/`

Installed by hand (`chrome://extensions` → "Load unpacked"), since it is
not in the Web Store. Put it in whichever browser your sessions drive —
the one where Claude in Chrome is installed; any Chromium will do. The id
is stable: the manifest carries a public key, without which the browser
would hand out a new address after every reinstall, and the daemon checks
that address.

| File | What it is |
|------|------------|
| `manifest.json` | MV3; permissions `activeTab`, `tabGroups`, `storage`, access limited to `127.0.0.1:8787` |
| `background.js` | service worker: capture, cropping, talking to the daemon, remembering "tab group → session", the queue of a shot sequence, the language |
| `overlay.js` | what you see on the page: the frame, the input field, the element selector, the markup editor, the sequence strip; lives in a Shadow DOM |
| `i18n.js` | reads `_locales/<lang>/messages.json` itself — chrome.i18n cannot be switched; shared by all three of the above |
| `_locales/{uk,en,cs,ru,kk}/messages.json` | extension strings |
| `popup.html`, `popup.js` | settings window: is the daemon alive, which groups are bound to which sessions, which language |

The private key lives in `~/.laserbeak/extension-key.pem` — it is not in
the repository and must never be.

### How it works

```
⌘⇧E (or click the icon, or right-click the page)
  └─ background: language from the daemon, executeScript i18n.js + overlay.js
      └─ drag a region with the mouse
          ├─ the overlay hides (else it lands in its own screenshot)
          ├─ elementFromPoint → selector of the element under the region
          └─ background: captureVisibleTab → crop ×dpr → storage.session
              └─ "What's wrong with it?" field + session picker
                  ├─ "Mark up" (optional): draw over the shot
                  │   └─ background: lb:mark → the drawn shot replaces the clean one
                  ├─ "Next shot" (optional): this shot + comment → the queue,
                  │   and straight back to dragging a region
                  └─ POST /sessions/shot — the queue and this shot, in order
```

The extension knows nothing of its own about sessions: it takes the list
from `/state`, and the daemon assembles the prompt.

### Marking up a shot

"Mark up" on the preview, or a click on the preview itself, opens an
editor over the page: freehand, arrow, circle and rectangle in six
colours, with Shift straightening a shape (circle, square, 45° arrow).

- **Shapes are vectors in the shot's own pixels**, not pixels on a
  canvas. That is what makes undo work, and why reopening the editor shows
  the clean shot with the same shapes, still editable.
- **A small region is enlarged — on screen and in the output.** The
  editor fits the shot to the screen, up to 8× its size on the page. The
  exported image is the shot scaled by a whole number without smoothing:
  otherwise a line four screen pixels thick would come out as half a pixel
  on a region a hundred pixels wide.
- **The clean shot stays in `storage.session`** next to the drawn one.
  Clearing every mark restores it instead of re-encoding the drawing of
  nothing; it is never sent to the daemon.
- **The daemon is told the marks are there** (`marked: true`) and says so
  in the prompt. A red box drawn over an interface reads as part of the
  interface; without the note the session goes looking for it in the code.

### A sequence of shots

"Next shot" puts the current shot aside with its comment and marks, and
the frame comes straight back for the next one — the page scrolls under
it. Enter on the last card sends them all as one prompt, numbered.

- **The queue lives in the service worker's `storage.session`**, not in
  the overlay. The overlay dies with the page, and the next step is often
  on another page: Esc keeps the queue, ⌘⇧E anywhere continues it.
- **Esc drops only the current shot.** A shot already queued is removed
  with the × on its thumbnail.
- **At most 8 shots** — the same `MAX_SERIES` in the daemon and in the
  extension. `storage.session` holds 10 MB for the whole extension, so a
  queue of large regions can run out sooner; then "Next shot" says so
  rather than losing a shot.

### Language

The extension speaks the language picked for Laserbeak. The service
worker asks the daemon (`/settings`) when it wakes up and again at the
start of every capture, so a change in the app reaches the next capture;
the last known language is kept for when the daemon is down, and without
it the browser's own language is used.

`chrome.i18n` cannot be switched at all — it is nailed to the browser —
so `i18n.js` reads `_locales/<lang>/messages.json` itself and repeats
chrome.i18n's placeholder rules. The service worker and the settings
window load the table directly; the overlay gets it from the service
worker by message, so `_locales` never has to be exposed to web pages. A
key missing from the table falls back to chrome.i18n rather than to a
blank button.

What cannot follow: the extension's name and description and the
shortcut's description in `chrome://extensions` — those come from the
manifest and stay in the browser's language.

## Quick commands — `shell/`

| File | What it is |
|------|------------|
| `laserbeak.zsh` | `start` and `stop` for zsh; `install.sh` adds one `source` line for it to `~/.zshrc` |
| `tmux.conf` | the tmux config for `start` sessions: invisible, mouse on, long history, a closed tab kills its session |

`start "name"` runs Claude Code inside tmux with the label; `start codex
"name"` does the same with Codex. Without a prompt of your own, the first
prompt asks the agent to read the project's documentation and wait.
`stop` lists the `start` sessions with their memory, `stop name` kills
one, `stop -a` the detached ones — `kill-session` only, never
`kill-server`. All text, the first prompt included, is in the language
picked for Laserbeak.

## Reply cards — `claude/reply-cards/`

A Claude Code mod: it adds the reply layout to the system prompt
(`prompt.compose`) and draws replies as numbered cards coloured by title
(`ui.render` on `AssistantMessage`) — light blue for what changed,
yellow for "important", purple for questions. Without it the same markup
reads as plain markdown.

The repository is a folder marketplace (`.claude-plugin/marketplace.json`),
and `install.sh` installs `reply-cards@laserbeak` at the user scope. A
plugin from a folder marketplace is read from that folder itself, so a
`git pull` updates the mod too; `/reload-plugins` picks it up in a
running session. `claude plugin test claude/reply-cards` runs its tests.

## Scripts — `scripts/`

| Script | What it does |
|--------|--------------|
| `install.sh` | full install: language, dependencies, build, LaunchAgents, hooks, `start`/`stop`, the reply-cards mod |
| `lang.sh` | every line the install scripts print, in five languages — `say key args`; the language is `LB_LANG` → `LASERBEAK_LANG` → `config.json` → the system's |
| `lang.js` | the same table for Node scripts (`patch-settings.js`, `extension.js`) — parsed from `lang.sh`, so the text lives in one place |
| `extension.js` | `npm run extension`: the extension folder path to the clipboard, and what to click |
| `uninstall.sh` | removes everything, keeps the data |
| `build-app.sh` | builds the Mac app and puts it in `/Applications` |
| `team-id.sh` | resolves the signing Team ID from this machine's keychain, so the project builds for anyone |
| `check-l10n.py` | every string in every language, everywhere (including `scripts/lang.sh`) — `npm run check:l10n` |
| `patch-settings.js` | writes hooks into `~/.claude/settings.json`, or with `--codex` into `~/.codex/hooks.json`, leaving everything else alone |
| `archive-import.js` | one-off import of conversations still on disk |
| `make-lucide.py` | generates `LucideIcons.swift` from SVG |
| `make-icon.py` | generates the app icon from an image |

## The hook — `hooks/hook.sh`

A single `curl`, shared by Claude Code and Codex: `hook.sh <event>
[agent]`, where the hook entry itself says `codex` — nothing is guessed.
Passes as headers what the payload does not carry:

| Header | Source | Why |
|--------|--------|-----|
| `X-Agent` | the second argument | `claude` or `codex` |
| `X-Claude-Label` | `$CLAUDE_LABEL` | session name |
| `X-App-Bundle` | `$__CFBundleIdentifier` | which editor to open on click |
| `X-Tmux-Pane` | `$TMUX_PANE` | where to type |
| `X-Hook-Ppid` | `$PPID` | to find the session's process |
| `X-Term-Program` | `$TERM_PROGRAM` | fallback for terminals |

## Codex

`start codex "name"` runs Codex exactly as `start` runs Claude Code: in
tmux, with the label. The hooks are the same file and the same path
through the daemon; what differs is kept in a few places:

| Where | What |
|-------|------|
| `patch-settings.js --codex` | `SessionStart`, `UserPromptSubmit`, `Stop`, `PermissionRequest` → `approval`, `Interrupt` → `interrupt`, `SessionEnd` |
| `events.js` | `approval` is always "permission needed"; `interrupt` ends the turn without a banner; a Codex transcript is not handed to the archive — it reads Claude's format only |
| `procs.js` | a process named `codex` counts as an agent, for the exact "session → pid" link only |
| `reaper.js` | a Codex session is never judged by counting processes |
| `state.js` | `agent` in every session; mode and effort are empty for Codex |
| `server.js` | mode switching, `/model` and `/effort` refuse a Codex session with `409` |
| the app | marks the session "Codex" and offers neither the mode picker nor model and effort |

Not there yet: the conversation archive for Codex (its rollout files are
a different format).

## The guard — `hooks/guard-tmux.sh`

A `PreToolUse` hook on `Bash` (see `.claude/settings.json`). It blocks
`tmux kill-server` unless the command names its own socket with `-L` or
`-S`, because that one command closes every Claude Code session on the
machine at once. Why it is there: **`tmux kill-server` in a test kills
the real work** in `docs/decisions.md`.
