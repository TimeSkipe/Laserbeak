# Architecture

## The whole picture

```
┌─ Claude Code or Codex ───────────────────────────────────┐
│  a session in a WebStorm tab, started with `start`       │
│  (inside tmux — shell/laserbeak.zsh)                     │
└───────────────┬──────────────────────────────────────────┘
                │ hooks: SessionStart, UserPromptSubmit,
                │        Stop, PermissionRequest, Notification,
                │        SessionEnd (Codex: + Interrupt, no Notification)
                ▼
        hooks/hook.sh  ── POST ──►  127.0.0.1:8787
                                          │
┌─────────────────────────────────────────▼────────────────┐
│  Daemon (Node, LaunchAgent com.laserbeak.daemon)         │
│                                                          │
│   state        sessions, projects, history               │
│   watching     processes, tmux panes, modes              │
│   actions      keys into a session: mode, model, shots   │
│   settings     language, banners, sounds — config.json   │
│   updates      is there a newer version on GitHub        │
│                                                          │
│   HTTP on 127.0.0.1 only — not configurable              │
└───────┬───────────────────────────────┬──────────────────┘
        │ 127.0.0.1                     │ 127.0.0.1
        ▼                               ▼
  Laserbeak.app (macOS)           browser extension
  window + menu bar + banners     drag a region on a page →
  ← the daemon keeps it alive     screenshot into ~/.laserbeak/shots/ →
                                  a text prompt with the path to it

  Inside every Claude Code session, the reply-cards mod
  (claude/reply-cards) draws replies as coloured cards.
```

## Why it is built this way

### The daemon is separate from the app

Notifications have to work even when no window is open. State has to
survive an app restart.

That requires the logic to live in a process that does not depend on any
interface. Hence a standalone LaunchAgent, with the app merely rendering
its state.

The consequence worth holding on to: **clients compute nothing**. A
custom session name, for instance, is applied in the daemon rather than
in the app — which is why it reads the same in the window, in the menu
bar, in the extension and in notifications. Settings follow the same
rule: they live in `config.json`, the daemon validates and applies them,
the window only shows them and sends changes back.

### Hooks are only a bridge

`hooks/hook.sh` does nothing but `curl` to localhost. The reason is
simple: a hook runs inside the Claude Code session and holds it up. One
local request is milliseconds. Put an `osascript` or a file parser in
there and every action in the session would drag.

If the daemon is down, `curl` fails silently and the hook exits 0. The
user's work never suffers.

### `start` is part of the install, not a tip

Typing into a session from outside is only possible through a terminal
Laserbeak can reach — tmux (see `docs/decisions.md`). `start` runs the
agent inside tmux with a label, and without it a session gets neither
screenshots from the browser nor mode or model switches from the app.

So `start` and `stop` live in the repository (`shell/laserbeak.zsh`) and
`install.sh` wires them into `~/.zshrc` with one `source` line. They
used to exist only in one person's `~/.zshrc`, and an install on any
other machine quietly ended up without them.

### Two agents, one path

Codex has hooks too, with the same events and the same format as Claude
Code, so it goes through the same `hook.sh` and the same daemon — the
hook entry adds `codex`, and every session carries `agent`. Everything
built on top (statuses, banners, typing through tmux, screenshots from
the browser) works for both without knowing the difference.

Where the two really differ, the daemon says so instead of guessing:
the Shift+Tab mode cycle and `/model`/`/effort` are Claude Code's, so a
Codex session refuses them, and the app does not offer them there; its
transcript is a different format, so the archive is Claude-only for now.

### Two sources of knowledge about sessions

**Hooks** report events: a session opened, a turn started, a turn
finished, permission is needed. But they only know about sessions started
**after** the hooks were installed.

**Process inspection** (`src/inspect.js`) sees what hooks cannot:
terminal tabs, live `claude` processes, projects open in an IDE. This is
where "sessions without notifications" come from — they are running, but
the daemon never heard of them.

Both sources are merged in `src/state.js`.

### The browser is the second client

The `extension/` (Chrome, Brave — any Chromium) reaches the daemon over
the same HTTP on `127.0.0.1` the Mac app uses.

The same rule applies: **the extension computes nothing**. It takes the
session list and the language from the daemon, and the prompt text is
assembled by the daemon in `shots.js`.

The image travels as text: the daemon writes it to a file and sends the
session a path, which Claude Code opens with its own `Read`. That is why
`input.js` knows nothing about screenshots — to it, this is an ordinary
prompt.

The price of admitting a browser is that trusting localhost stopped being
free. The daemon inspects `Origin`: a page from the network cannot reach
it even from here.

### One language for everything

The language is picked once — at install time (`LASERBEAK_LANG`) or later
in the window — and lives in `config.json`. Everything a person reads
follows it:

| Where | How it gets there |
|-------|-------------------|
| banners, history, API errors, the screenshot prompt | the daemon, `src/i18n.js`, on the fly |
| the window and menu bar | `AppleLanguages` of the app, set from the config at every launch — takes effect on relaunch |
| the browser extension | asks the daemon (`/settings`), reads `_locales/<lang>` itself |
| `start` / `stop` and the first prompt | ask the daemon, fall back to `config.json` |
| install, uninstall, build scripts | `scripts/lang.sh`: `LASERBEAK_LANG`, then `config.json`, then the system's languages |

Ukrainian, English, Czech, Russian and Kazakh. `auto` means the first of
the macOS interface languages Laserbeak knows — the same rule macOS uses
for the window, so `auto` also lands on the same language everywhere.
Logs stay in one language on purpose.

`scripts/check-l10n.py` checks that every string exists in every
language, in all five places.

## Data flow

### An event from a session

```
Claude Code
  └─ hook.sh <event>            + headers: label, tmux pane, ppid
      └─ POST /hook/<event>
          └─ events.handle()
              ├─ roots.resolve(cwd)        which project is this
              ├─ projects.touch()          remember the project
              ├─ archive.ingest()          read new transcript bytes
              ├─ state.touch()             update the session
              └─ notify.send()             notify if warranted
```

The hook's response is sent **before** processing — the session never
waits.

### Showing state

```
app ── GET /state (every 2 s) ──► state.snapshot()
                                   ├─ live sessions + mode
                                   ├─ projects + tabs + processes
                                   ├─ event history
                                   └─ language + update summary
```

`snapshot()` must stay fast. Everything expensive — process inspection,
reading the permission mode, asking GitHub — is cached and refreshed in
the background.

### Notifications

```
notify.send()                   is this kind on in config.notify?
  │                             is this session muted?
  ├─ is the Mac app listening?  ──► outbox.push()
  │                                   └─ GET /events/wait (long-poll)
  │                                       └─ banner from Laserbeak:
  │                                          project icon + event badge
  └─ no                         ──► terminal-notifier
```

Long-polling rather than polling: the request hangs until an event
appears, so the banner shows up instantly and almost nothing crosses the
wire.

Which events show a banner and with which sound is set in the window
(Settings → Notifications) and stored as `notify` and `sounds` in
`config.json`. Muting a single session is stronger than the general rule.

### Typing into a session

```
POST /sessions/input | /sessions/shot | /sessions/command | /sessions/mode
  ├─ daemon-started session?  ──► terminals.write()  (its own pty)
  ├─ session inside tmux?     ──► tmux.send()        (send-keys)
  └─ neither                  ──► 409 with an explanation
```

Why there is no other way — see the TIOCSTI section in
`docs/decisions.md`.

### Updates

```
updates.start()        every 6 h (and when HEAD moved)
  └─ GET api.github.com/repos/<origin>/commits?sha=<branch>
       └─ where is our HEAD in that list → behind N / ahead / current
            └─ new tip? → banner (kind "update")

Settings → Updates
  └─ what is new + the commands to run: cd <repo>, git pull --ff-only,
     npm run install:all — installing is the person's (or Claude Code's)
```

Read-only on purpose: Laserbeak never touches the working copy and never
rebuilds itself. Details in `docs/decisions.md`.

## The life of a session

```
start "name"
  └─ tmux new-session ─► claude
       │
       ├─ SessionStart      → the session appears in state
       ├─ UserPromptSubmit  → status "working", turn timer starts
       ├─ Stop              → status "done", notification
       ├─ PermissionRequest → permission needed, the moment the dialog appears
       ├─ Notification      → the same 6 s later (ignored), or waiting for input
       └─ SessionEnd        → the session disappears
```

If `SessionEnd` never arrives (the tab was killed), `src/reaper.js`
collects the session — every half minute, or on the Refresh button.

## Storage

Code lives in the repository, user data in `~/.laserbeak/`:

| File | What it is |
|------|------------|
| `config.json` | settings and rules, re-read on the fly |
| `projects.json` | project registry with colours and icons |
| `sessions.json` | custom session names and notification switches |
| `sessions-live.json` | live sessions, so a daemon restart is survivable |
| `archive/` | conversations + `index.json` |
| `shots/` | region screenshots from the browser; last 200 or 7 days |
| `events.jsonl` | log of every event |
| `update.json` | the last update check |
| `extension-key.pem` | the extension's private key, mode `0600` |
| `app-quit` | marker of a deliberate app quit |
| `daemon.log`, `app.log` | logs: the daemon's, and the Mac app's (`AppLog`); over 5 MB / 2 MB the older half moves to `.1` |
| `errors.log` | only what went wrong, from both the daemon and the app: route, code, reason, stack; mode `0600` |

## Network and access

The daemon listens on `127.0.0.1` and nowhere else; the address is not
in the config at all. Every client — the app, the extension, `hook.sh`,
`start` — is on the same computer.

Two checks stand at the entrance in `src/server.js`: a request not from
`127.0.0.1` gets `403` (a guard, it cannot arrive anyway), and a request
whose `Origin` is a web page gets `403` too. There is no access key: it
existed for the phone app, which is gone.

The only outbound request is the update check to `api.github.com`, every
six hours, switchable off in the window.

### The Mac app can no longer just vanish

It is the menu bar and the banners with project icons; without it,
banners fall back to the faceless `terminal-notifier`. So the daemon
checks every ten seconds whether it is reachable and brings it back —
roughly a minute from crash to recovery.

The sign of life is not a row in the process table (a process can hang
around doing nothing) but an open request on `/events/wait`.

launchd's `KeepAlive` is no good here: the app must be launched via
`open`, which exits immediately, so launchd would relaunch it in a loop.
Details in `docs/decisions.md`.

A deliberate quit ("Quit" in the menu bar) leaves `~/.laserbeak/app-quit`
behind — while that file exists, the daemon leaves the app alone. It is
removed on the next launch.
