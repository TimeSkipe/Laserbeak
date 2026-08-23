# HTTP API

The daemon listens on `bindHost:port` from the config — by default
`127.0.0.1:8787`, meaning it is not on the network at all.

The phone reaches it through the Mac app: the app holds an encrypted
connection and forwards requests here over loopback. So everything below
works from the phone as well, just not directly.

`"bindHost": "0.0.0.0"` enables the fallback path — plain HTTP from the
network, behind the key. See `docs/architecture.md`.

## Access

Anything arriving from somewhere other than `127.0.0.1` must bring a key:

```
Authorization: Bearer <key>
```

An `X-Laserbeak-Token` header with the bare key is accepted too. Without
a key — `401` and no data.

| From | What is allowed |
|------|-----------------|
| `127.0.0.1` | everything, no key needed |
| network, with key | everything except what is marked below |
| network, no key | nothing |

"Network" only exists here when the fallback is enabled
(`bindHost: 0.0.0.0`). By default nothing arrives from the network at
all.

Only from `127.0.0.1`, even with a key:

- `POST /hook/*` — writes to state;
- `POST /sessions/spawn` — starts a new process on the machine;
- `GET /auth/token`, `POST /auth/rotate` — the key itself.

The rest is reading and acting on sessions that already exist, and that
is exactly what the phone uses.

Complaints about a bad key are logged at most three times per address:
otherwise someone else's script hammering once a second would inflate the
log overnight.

### Where the request came from

Localhost means trust, and as long as only our own apps came through it,
that was honest. A browser changes the terms: foreign code ends up there
by itself the moment you open a tab.

A third-party page cannot read the response — it will not get an
`Access-Control-Allow-Origin` header. But a `POST` with a simple
`Content-Type` flies without a preflight, which means **the action
executes**, even though nobody sees the reply; for `/sessions/spawn` you
do not even need a `sid`.

So the daemon inspects `Origin`. A page cannot forge it — the browser
sets it:

| `Origin` | Who that is | Allowed |
|----------|-------------|---------|
| absent | our own apps, `curl`, `hook.sh` | yes |
| `chrome-extension://…` | the extension | yes, if it matches `extensionId` |
| `http://…`, `https://…` | a page in a browser | never — `403` |

An empty `extensionId` in the config means "any extension"; pages from
the network are refused either way.

---

## The access key

The key lives in `~/.laserbeak/token` (mode `0600`) and is created on
first run. The same key serves as the password for the encrypted
connection with the phone — so the secret is transferred exactly once,
from a QR code.

### `GET /auth/token`

Localhost only. `{ ok, token }` — precisely what the Mac app shows in the
QR code.

### `POST /auth/rotate`

Localhost only. A new key. Every connected phone loses access until it
scans the code again.

---

## State

### `GET /state`

Everything an app needs. Polled every 2 seconds.

```jsonc
{
  "ok": true,
  "host": "my-macbook",
  "port": 8787,
  "bindHost": "127.0.0.1",    // 0.0.0.0 = HTTP fallback enabled
  "addresses": [{ "interface": "en0", "address": "192.168.1.137" }],

  "projects": [{
    "path": "/…/storefront",
    "name": "storefront",
    "status": "working",        // needs-input | waiting | working | idle | offline
    "isOpen": true,             // show in the list
    "discovered": false,        // found via processes, not via hooks
    "settings": { "color": "orange", "icon": "rocket" },

    "sessionCount": 2,
    "terminals": 3,             // terminal tabs in the project
    "claudeTerminals": 2,       // of those, running claude
    "plainTerminals": 1,
    "claudeProcesses": 2,
    "untracked": 0,             // live claude processes the daemon knows nothing about

    "sessions": [ /* see below */ ]
  }],

  "sessions": [{
    "sid": "…",
    "label": "backend",         // from CLAUDE_LABEL
    "displayName": "Backend",   // taking the custom name into account
    "alias": "Backend",
    "project": "storefront",
    "projectPath": "/…/storefront",
    "cwd": "/…/storefront/functions",

    "status": "waiting",
    "permissionMode": "auto",   // auto | plan | acceptEdits | default
    "effort": "high",           // low | medium | high | xhigh | max
    "notifyEnabled": true,
    "canInput": true,           // whether prompts can be typed in
    "hosted": false,            // started by the daemon itself
    "lastBrowserUse": 0,        // ms; when this session last drove a browser
    "tmuxPane": "%3",
    "pid": 88867,

    "turns": 12,
    "turnSeconds": null,        // set while a turn is running
    "lastTurnSeconds": 64.2,
    "totalWorkSeconds": 2832,
    "tokens": { "input": 0, "cacheWrite": 0, "cacheRead": 0,
                "output": 0, "thinking": 0, "total": 0,
                "messages": 0, "model": "claude-opus-5" }
  }],

  "history": [{ "ts": 0, "sid": "…", "kind": "stop", "message": "…" }]
}
```

### `POST /refresh`

The same as `/state`, but does everything immediately first: process
inspection, session liveness checks, transcript ingestion, mode cache
reset. This is the Refresh button.

Adds `removed` to the response — sessions found to be dead.

### `GET /health`

`{ ok, pid, outbox: { seq, waiting, clientAlive } }`

---

## Events from sessions

### `POST /hook/<event>`

Accepted **from localhost only**. The body is the JSON Claude Code passed
to the hook. The response is sent before processing, so the session never
waits.

Events: `session-start`, `prompt`, `stop`, `notification`, `session-end`.
The old name `permission` is still accepted — sessions opened before the
rename still send it.

Headers: `X-Claude-Label`, `X-App-Bundle`, `X-Tmux-Pane`, `X-Hook-Ppid`,
`X-Term-Program`.

---

## Actions on a session

### `POST /sessions/input`

```json
{ "sid": "…", "text": "prompt" }
```

Response: `{ "ok": true, "via": "tmux" }` or `"terminal"`.

`409` if the session was started without a go-between — there is no way
to type into it.

### `POST /sessions/mode`

```json
{ "sid": "…", "mode": "plan" }
```

Presses Shift+Tab and re-reads the indicator until it gets the mode you
asked for. The response includes `presses` — how many it took.

### `POST /sessions/command`

Claude Code slash commands. Exactly one field per request:

```json
{ "sid": "…", "model": "sonnet" }
{ "sid": "…", "effort": "high" }
{ "sid": "…", "compact": true }
```

| Field | Allowed |
|-------|---------|
| `model` | `default`, `opus`, `fable`, `sonnet`, `haiku` |
| `effort` | `low`, `medium`, `high`, `xhigh`, `max` |
| `compact` | `true` |

Technically this is the same input into a session, but with an allow-list:
the phone must not be able to send an arbitrary string as a command. An
unknown value gives `400`, a session without a go-between gives `409`.

**Important:** Claude Code remembers the model and effort choice as the
**default for new sessions** — exactly as when you change them by hand.
This is not our invention, it is how `/model` and `/effort` behave.

### `POST /sessions/shot`

A screenshot of a region of a page — what the browser extension sends.

```json
{
  "sid": "…",
  "image": "data:image/png;base64,…",
  "comment": "the button overflows the container",
  "url": "http://localhost:3000/checkout",
  "selector": "body > main.page > div.hero > button.cta",
  "text": "Checkout",
  "size": "420×180"
}
```

The daemon writes the image into `~/.laserbeak/shots/` and sends the
session an ordinary text prompt with the path to it:

```
Look at this screenshot: /Users/…/shots/a1b2c3d4-20260821-113612.png — the
button overflows the container. This is element body > main.page >
div.hero > button.cta, text "Checkout", http://localhost:3000/checkout.
Region 420×180.
```

So it is the same input, just assembled by the daemon: Claude Code opens
the image with its own `Read`. The text is deliberately **a single line**
— every `\n` in the input is an Enter, i.e. a separate submission.

Response: `{ ok, via, file, bytes }`.

`400` — missing `sid`/`image`, or the image will not parse; `404` — no
such session; `409` — the session was started without a go-between
(checked **before** the file is written, so no litter is left on disk).

The body limit here is 8 MB rather than the usual 2: base64 adds a third
to the image's weight.

Screenshots sweep themselves — the last 200 or 7 days, whichever comes
first.

### `POST /sessions/interrupt`

Ctrl-C into the session: stop the work without closing it.

### `POST /sessions/spawn`

Localhost only — it starts a new process.

```json
{ "projectPath": "/…", "label": "name", "prompt": "first prompt" }
```

### `POST /sessions/stop`

End a session the daemon started.

### `POST /sessions/forget`

Remove a session from the list by hand. The session itself keeps running.

### `POST /sessions/settings`

```json
{ "sid": "…", "alias": "Backend", "notify": false }
```

An empty `alias` restores the original label.

### `GET /sessions/output/<sid>`

Raw terminal output of a session the daemon started. For debugging.

---

## Projects

### `POST /projects/settings`

```json
{ "path": "/…", "settings": { "color": "orange", "icon": "rocket" } }
```

An empty value clears the setting.

### `POST /projects/forget`

Remove a project from the registry.

---

## Conversation archive

### `GET /archive`

List of sessions whose conversations have been saved.

### `GET /archive/<sid>?limit=300&subagents=1`

```jsonc
{
  "session": { "sid": "…", "project": "…", "messages": 568 },
  "messages": [{
    "ts": 0,
    "role": "user",           // or "assistant"
    "text": "…",
    "tools": ["Bash"],        // tool names; contents are omitted on purpose
    "uuid": "…",
    "sidechain": false,       // a subagent's message
    "replySeconds": 43.8      // only on the last reply of a turn
  }]
}
```

`limit` returns the tail of the conversation; without it, everything.

---

## Notifications

### `GET /events/wait?since=<seq>`

Long-poll: the request hangs until an event appears, or for 20 seconds.

- `since=0` means "just started" — the daemon returns only new events
  instead of dumping the backlog;
- a `since` greater than the current one means the daemon was restarted,
  so everything accumulated is returned.

```json
{ "ok": true, "seq": 12, "notifications": [{
  "seq": 12, "kind": "stop", "sid": "…",
  "session": "backend", "project": "storefront",
  "color": "orange", "icon": "rocket",
  "message": "Finished\n1m 4s · 45k tokens",
  "sound": "Glass", "appBundle": "com.jetbrains.WebStorm"
}] }
```

Only the daemon filters — the client shows everything it receives.
