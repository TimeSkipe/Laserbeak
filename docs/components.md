# Components

## Daemon — `src/`

### Core

| File | Responsibility |
|------|----------------|
| `daemon.js` | entry point; starts the server, Bonjour and two timers: transcript ingestion (2 s) and session liveness checks (30 s) |
| `server.js` | HTTP API; decides where each request is allowed to come from |
| `state.js` | memory: live sessions, history, per-project rollups; `snapshot()` assembles everything for `/state` |
| `events.js` | hook event handling — the only place where user actions mutate state |
| `config.js` | config from `~/.laserbeak/config.json`, re-read on the fly |
| `auth.js` | access key: creation, storage with mode `0600`, constant-time comparison |
| `paths.js` | every path in one place; the migration from the old name lives here too |
| `log.js` | logs to stdout, which launchd writes to a file |
| `i18n.js` | user-visible text in uk/en/cs; logs stay in one language on purpose |

### Watching

| File | Responsibility |
|------|----------------|
| `inspect.js` | process inspection: terminal tabs, live `claude` processes, projects open in an IDE |
| `procs.js` | linking a session to its process: searching up and down the tree for `claude` |
| `roots.js` | which directory counts as the project (IDE → `.git` → the directory itself) |
| `tokens.js` | token accounting from the transcript |
| `modes.js` | reading the permission mode and effort level from the Claude Code status line |
| `reaper.js` | collecting sessions that are no longer alive |
| `appguard.js` | keeps the Mac app alive: it holds the channel to the phone |

### Actions

| File | Responsibility |
|------|----------------|
| `input.js` | where to write into a session: own terminal or tmux pane |
| `tmux.js` | input into WebStorm sessions: `send-keys`, Shift+Tab, `capture-pane` |
| `terminals.js` | sessions the daemon started in its own pseudo-terminal |
| `pty-bridge.py` | the pseudo-terminal itself; standard library only |
| `notify.js` | notifications: through the app, or via `terminal-notifier` as fallback |
| `shots.js` | region screenshots from the browser: save the file, assemble the prompt, sweep old ones |
| `outbox.js` | notification queue for the Mac app (long-poll) |
| `bonjour.js` | network advertisement via `dns-sd` |

### Storage

| File | Responsibility |
|------|----------------|
| `projects.js` | project registry: names, editor, colour and icon |
| `sessionSettings.js` | custom session names and notification switches |
| `archive.js` | conversation archive; distillation, deduplication, incremental reads |

## Apps — `app/`

The Xcode project is generated from `app/project.yml` with `xcodegen`;
the `.xcodeproj` itself is not kept in git.

### Shared — `app/Shared/`

Compiled for both platforms.

| File | What it is |
|------|------------|
| `Models.swift` | mirror of the JSON from `/state`; **hand-written decoding**, see below |
| `DaemonClient.swift` | polling `/state` and every action; unaware of which path the data takes |
| `Transport.swift` | the path itself: shared protocol and `HTTPTransport` with the key |
| `PeerLink.swift` | the direct encrypted channel: TLS-PSK, framing, the phone's side |
| `Pairing.swift` | memory of the laptop; key in the Keychain, address in settings |
| `Discovery.swift` | finding the laptop: direct channel and fallback address, merged by name |
| `Views.swift` | project list, session row, editors, details |
| `ChatView.swift` | conversation with an input field; updates live |
| `Markdown.swift` | our own markdown rendering: headings, lists, tables, code |
| `LucideIcons.swift` | **generated** file — do not edit by hand |
| `Resources/Localizable.xcstrings` | String Catalog: 205 keys × uk/en/cs |
| `Palette.swift` | project colours |
| `QRCode.swift` | pairing-link format + drawing the code |
| `PlatformLayout.swift` | sizes that apply on the Mac only |

### macOS — `app/macOS/`

| File | What it is |
|------|------------|
| `LaserbeakApp.swift` | entry point; agent app (no Dock icon), window + menu bar; the close button hides rather than quits |
| `MacRootView.swift` | window and menu bar contents |
| `Notifications.swift` | banners from the app itself, image with the project icon, its own log file |
| `PeerServer.swift` | listener for the phone; forwards requests to the daemon on `127.0.0.1` |
| `PairingView.swift` | QR code with the key, direct-channel status, key rotation |

### iOS — `app/iOS/`

| File | What it is |
|------|------------|
| `LaserbeakApp.swift` | entry point |
| `PhoneRootView.swift` | the screen and path selection: direct channel, otherwise HTTP with the key |
| `QRScanner.swift` | code scanner (AVFoundation); without a key the code is rejected |

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
| `background.js` | service worker: capture, cropping, talking to the daemon, remembering "tab group → session", the queue of a shot sequence |
| `overlay.js` | what you see on the page: the frame, the input field, the element selector, the markup editor, the sequence strip; lives in a Shadow DOM |
| `i18n.js` | the extension's language: the browser's, or the one picked in settings; shared by all three of the above |
| `_locales/{uk,en,cs}/messages.json` | extension strings |
| `popup.html`, `popup.js` | settings window: is the daemon alive, which groups are bound to which sessions, language |

The private key lives in `~/.laserbeak/extension-key.pem` — it is not in
the repository and must never be.

### How it works

```
⌘⇧E (or click the icon, or right-click the page)
  └─ background: executeScript i18n.js + overlay.js
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
from `/state`, and the daemon assembles the prompt. Same rule as for the
Mac and the phone — the client displays, the daemon decides.

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

By default the extension speaks the browser's UI language (not the
system's). The settings window can pin it to Ukrainian, English or Czech.

`chrome.i18n` cannot be switched at all — it is nailed to the browser —
so for a pinned language `i18n.js` reads `_locales/<lang>/messages.json`
itself and repeats chrome.i18n's placeholder rules. The service worker
and the settings window load the table directly; the overlay gets it
from the service worker by message, so `_locales` never has to be
exposed to web pages. A key missing from the table falls back to
chrome.i18n rather than to a blank button.

What cannot follow the switch: the extension's name and description and
the shortcut's description in `chrome://extensions` — those come from
the manifest and stay in the browser's language.
- **The daemon is told the marks are there** (`marked: true`) and says so
  in the prompt. A red box drawn over an interface reads as part of the
  interface; without the note the session goes looking for it in the code.

## Scripts — `scripts/`

| Script | What it does |
|--------|--------------|
| `install.sh` | full install: dependencies, build, LaunchAgents, hooks |
| `uninstall.sh` | removes everything, keeps the data |
| `build-app.sh` | builds the Mac app and puts it in `/Applications` |
| `team-id.sh` | resolves the signing Team ID from this machine's keychain, so the project builds for anyone |
| `install-phone.sh` | builds and installs on an iPhone (works over Wi-Fi too) |
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
| `X-Tmux-Pane` | `$TMUX_PANE` | where to type prompts |
| `X-Hook-Ppid` | `$PPID` | to find the session's process |
| `X-Term-Program` | `$TERM_PROGRAM` | fallback for terminals |

## Codex

`start codex "name"` (in `~/.zshrc`) runs Codex exactly as `start` runs
Claude Code: in tmux, with the label. The hooks are the same file and
the same path through the daemon; what differs is kept in a few places:

| Where | What |
|-------|------|
| `patch-settings.js --codex` | `SessionStart`, `UserPromptSubmit`, `Stop`, `PermissionRequest` → `approval`, `Interrupt` → `interrupt`, `SessionEnd` |
| `events.js` | `approval` is always "permission needed"; `interrupt` ends the turn without a banner; a Codex transcript is not handed to the token counter or the archive — they read Claude's format only |
| `procs.js` | a process named `codex` counts as an agent, for the exact "session → pid" link only |
| `reaper.js` | a Codex session is never judged by counting processes |
| `state.js` | `agent` in every session; mode and effort are empty for Codex |
| `server.js` | mode switching, `/model` and `/effort` refuse a Codex session with `409` |

Not there yet: tokens and the conversation archive for Codex (its
rollout files are a different format), and the apps still offer the mode
picker on a Codex session (the daemon refuses it with a clear message).

## The guard — `hooks/guard-tmux.sh`

A `PreToolUse` hook on `Bash` (see `.claude/settings.json`). It blocks
`tmux kill-server` unless the command names its own socket with `-L` or
`-S`, because that one command closes every Claude Code session on the
machine at once. Why it is there: **`tmux kill-server` in a test kills
the real work** in `docs/decisions.md`.

