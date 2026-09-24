# Architecture

## The whole picture

```
┌─ Claude Code or Codex ───────────────────────────────────┐
│  a session in a WebStorm tab (inside tmux)               │
│  or a session the daemon started itself (Claude only)    │
└───────────────┬──────────────────────────────────────────┘
                │ hooks: SessionStart, UserPromptSubmit,
                │        Stop, Notification, SessionEnd
                │        (Codex: + PermissionRequest, Interrupt)
                ▼
        hooks/hook.sh  ── POST ──►  127.0.0.1:8787
                                          │
┌─────────────────────────────────────────▼────────────────┐
│  Daemon (Node, LaunchAgent com.laserbeak.daemon)         │
│                                                          │
│   state        sessions, projects, history               │
│   watching     processes, tmux panes, modes              │
│   actions      typing into a session, mode, spawning     │
│   storage      project registry, conversation archive    │
│                                                          │
│   HTTP on 127.0.0.1:8787 only — invisible on the network │
└───────┬──────────────────────────────────────────────────┘
        │ 127.0.0.1
        ▼
  Laserbeak.app (macOS)
  window + menu bar + notifications
  + listener for the phone  ← the daemon keeps it alive
        │
        └─ TLS-PSK over AWDL, bypassing the router ──► Laserbeak (iOS)

  The browser extension talks to the daemon too, also over 127.0.0.1:
  drag a region on a page → screenshot into ~/.laserbeak/shots/ →
  an ordinary text prompt into the session with the path to it
```

## Why it is built this way

### The daemon is separate from the apps

Notifications have to work even when no window is open. State has to
survive an app restart. The phone has to see exactly what the Mac sees.

All of that requires the logic to live in a process that does not depend
on any interface. Hence a standalone LaunchAgent, with the apps merely
rendering its state.

The consequence worth holding on to: **clients compute nothing**. A
custom session name, for instance, is applied in the daemon rather than
in the app — which is why it reads the same in the window, in the menu
bar, on the phone and in notifications.

### Hooks are only a bridge

`hooks/hook.sh` does nothing but `curl` to localhost. The reason is
simple: a hook runs inside the Claude Code session and holds it up. One
local request is milliseconds. Put an `osascript` or a file parser in
there and every action in the session would drag.

If the daemon is down, `curl` fails silently and the hook exits 0. The
user's work never suffers.

### Two agents, one path

Codex has hooks too, with the same events and the same format as Claude
Code, so it goes through the same `hook.sh` and the same daemon — the
hook entry adds `codex`, and every session carries `agent`. Everything
built on top (statuses, banners, typing through tmux, screenshots from
the browser) works for both without knowing the difference.

Where the two really differ, the daemon says so instead of guessing:
the Shift+Tab mode cycle and `/model`/`/effort` are Claude Code's, so a
Codex session refuses them; its transcript is a different format, so
tokens and the archive are Claude-only for now. Details in
`docs/components.md`, the traps in `docs/decisions.md`.

### Two sources of knowledge about sessions

**Hooks** report events: a session opened, a turn started, a turn
finished, permission is needed. But they only know about sessions started
**after** the hooks were installed.

**Process inspection** (`src/inspect.js`) sees what hooks cannot:
terminal tabs, live `claude` processes, projects open in an IDE. This is
where "sessions without notifications" come from — they are running, but
the daemon never heard of them.

Both sources are merged in `src/state.js`.

### The browser is the third client

The `extension/` (Chrome, Brave — any Chromium) has no transport of its
own: it reaches the daemon over the same HTTP on `127.0.0.1` the Mac app
uses. We deliberately do not route it through the app — that channel
exists only because the phone has no other way in, while a browser on
this very machine already has loopback.

The same rule as for the Mac and the phone applies: **the extension
computes nothing**. It takes the session list from `/state`, and the
prompt text is assembled by the daemon in `shots.js` — the extension has
no opinion of its own about how to talk to a session, and must not have
one.

The image travels as text: the daemon writes it to a file and sends the
session a path, which Claude Code opens with its own `Read`. That is why
`input.js` knows nothing about screenshots — to it, this is an ordinary
prompt.

The price of admitting a browser is that trusting localhost stopped being
free. The daemon now inspects `Origin`: a page from the network cannot
reach it even from here.

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
              ├─ tokens.scan()             count tokens
              ├─ state.touch()             update the session
              └─ notify.send()             notify if warranted
```

The hook's response is sent **before** processing — the session never
waits.

### Showing state

```
app ── GET /state (every 2 s) ──► state.snapshot()
                                   ├─ live sessions + tokens + mode
                                   ├─ projects + tabs + processes
                                   └─ event history
```

`snapshot()` must stay fast. Everything expensive — process inspection,
reading the permission mode — is cached and refreshed in the background.

### Notifications

```
notify.send()
  ├─ is the Mac app listening?  ──► outbox.push()
  │                                   └─ GET /events/wait (long-poll)
  │                                       └─ banner from Laserbeak
  └─ no                         ──► terminal-notifier
```

Long-polling rather than polling: the request hangs until an event
appears, so the banner shows up instantly and almost nothing crosses the
wire.

### Typing into a session

```
POST /sessions/input
  ├─ daemon-started session?  ──► terminals.write()  (its own pty)
  ├─ session inside tmux?     ──► tmux.send()        (send-keys)
  └─ neither                  ──► 409 with an explanation
```

Why there is no other way — see the TIOCSTI section in
`docs/decisions.md`.

## The life of a session

```
start "name"
  └─ tmux new-session ─► claude
       │
       ├─ SessionStart      → the session appears in state
       ├─ UserPromptSubmit  → status "working", turn timer starts
       ├─ Stop              → status "done", tokens, notification
       ├─ Notification      → permission needed, or waiting for input
       └─ SessionEnd        → the session disappears
```

If `SessionEnd` never arrives (the tab was killed), `src/reaper.js`
collects the session — every half minute, or on the Refresh button.

## Storage

Code lives in the repository, user data in `~/.laserbeak/`:

| File | What it is |
|------|------------|
| `config.json` | rules, re-read on the fly |
| `projects.json` | project registry with colours and icons |
| `sessions.json` | custom session names and notification switches |
| `sessions-live.json` | live sessions, so a daemon restart is survivable |
| `archive/` | conversations + `index.json` |
| `shots/` | region screenshots from the browser; last 200 or 7 days |
| `events.jsonl` | log of every event |
| `token` | access key, mode `0600` |
| `extension-key.pem` | the extension's private key, mode `0600` |
| `app-quit` | marker of a deliberate app quit |
| `daemon.log`, `app.log` | logs |

## Network and access

### The key

Anything arriving from somewhere other than `127.0.0.1` must bring a key:

```
Authorization: Bearer <key>
```

The key lives in `~/.laserbeak/token` with mode `0600` and is created on
first run. The phone gets it from a QR code — that is the only way to
connect.

Requests from localhost need no key: only someone already sitting at this
computer can make them.

| From | What is allowed |
|------|-----------------|
| `127.0.0.1` | everything, no key |
| network, with key | everything except `/hook/*`, `/sessions/spawn`, `/auth/*` |
| network, no key | nothing — `401` |

The key is still needed when the daemon is locked down: the phone goes
through the Mac app, and there the key serves as the encryption password.

### One path: through the Mac app

```
phone ──TLS-PSK over AWDL──► Laserbeak.app ──HTTP──► 127.0.0.1:8787
       (bypassing the router, encrypted)              (daemon)
```

By default the daemon listens on `127.0.0.1` **only** — it is not on the
network at all. The phone can only get to it through the Mac app.

The HTTP fallback is still in the code and switches on with one line of
config (`"bindHost": "0.0.0.0"`). The phone then works even with the app
closed, but traffic on the local network is in the clear — protected by
the key alone. `/state` then reports `bindHost`, and the app shows that
the fallback is enabled.

**The direct channel is held by the Mac app, not by the daemon**:
Network.framework is Apple's, and the daemon is written in Node. Devices
find each other over Bluetooth (`includePeerToPeer`), and the data flows
over AWDL — direct Wi-Fi between devices. No shared network is needed.
Encryption is TLS with a pre-shared key derived from the same access key.

The phone picks its own path and switches to the direct one the moment it
appears. If the direct channel goes quiet while the daemon really is
visible on the network, the phone falls back to HTTP for twenty seconds —
otherwise it would be stuck whenever the Mac sleeps. If there is nowhere
to fall back to (the daemon locked to `127.0.0.1`, as by default), the
phone stays on the direct channel and rebuilds it: the address from the
QR code is dead anyway in that case.

A break in the channel itself usually goes unnoticed: a request on a
stale connection is quietly retried on a fresh one, and "no connection"
is only shown after two failed polls in a row.

### The Mac app can no longer just vanish

Since it holds the only channel, its death blinds the phone. So the
daemon checks every ten seconds whether it is reachable and brings it
back — roughly a minute from crash to recovery.

The sign of life is not a row in the process table (a process can hang
around doing nothing) but an open request on `/events/wait`.

launchd's `KeepAlive` is no good here: the app must be launched via
`open`, which exits immediately, so launchd would relaunch it in a loop.
Details in `docs/decisions.md`.

A deliberate quit ("Quit" in the menu bar) leaves `~/.laserbeak/app-quit`
behind — while that file exists, the daemon leaves the app alone. It is
removed on the next launch.

### Why not plain Bluetooth

CoreBluetooth gives you ~180-byte packets and a few KB/s. A state
snapshot is 12 KB every two seconds; a session archive is up to two
megabytes. Over BLE that would crawl; over AWDL the same archive takes
66 ms.
