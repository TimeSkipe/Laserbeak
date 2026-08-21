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
| `background.js` | service worker: capture, cropping, talking to the daemon, remembering "tab group → session" |
| `overlay.js` | what you see on the page: the frame, the input field, the element selector; lives in a Shadow DOM |
| `_locales/{uk,en,cs}/messages.json` | extension strings; the browser picks the folder by its own UI language |
| `popup.html`, `popup.js` | settings window: is the daemon alive, which groups are bound to which sessions |

The private key lives in `~/.laserbeak/extension-key.pem` — it is not in
the repository and must never be.

### How it works

```
⌘⇧E (or click the icon, or right-click the page)
  └─ background: executeScript overlay.js
      └─ drag a region with the mouse
          ├─ the overlay hides (else it lands in its own screenshot)
          ├─ elementFromPoint → selector of the element under the region
          └─ background: captureVisibleTab → crop ×dpr → storage.session
              └─ "What's wrong with it?" field + session picker
                  └─ POST /sessions/shot
```

The extension knows nothing of its own about sessions: it takes the list
from `/state`, and the daemon assembles the prompt. Same rule as for the
Mac and the phone — the client displays, the daemon decides.

## Scripts — `scripts/`

| Script | What it does |
|--------|--------------|
| `install.sh` | full install: dependencies, build, LaunchAgents, hooks |
| `uninstall.sh` | removes everything, keeps the data |
| `build-app.sh` | builds the Mac app and puts it in `/Applications` |
| `team-id.sh` | resolves the signing Team ID from this machine's keychain, so the project builds for anyone |
| `install-phone.sh` | builds and installs on an iPhone (works over Wi-Fi too) |
| `patch-settings.js` | writes hooks into `~/.claude/settings.json`, leaving other settings alone |
| `archive-import.js` | one-off import of conversations still on disk |
| `make-lucide.py` | generates `LucideIcons.swift` from SVG |
| `make-icon.py` | generates the app icon from an image |

## The hook — `hooks/hook.sh`

A single `curl`. Passes as headers what the payload does not carry:

| Header | Source | Why |
|--------|--------|-----|
| `X-Claude-Label` | `$CLAUDE_LABEL` | session name |
| `X-App-Bundle` | `$__CFBundleIdentifier` | which editor to open on click |
| `X-Tmux-Pane` | `$TMUX_PANE` | where to type prompts |
| `X-Hook-Ppid` | `$PPID` | to find the session's process |
| `X-Term-Program` | `$TERM_PROGRAM` | fallback for terminals |
