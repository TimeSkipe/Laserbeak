# HTTP API

The daemon listens on `127.0.0.1:<port>` — the port comes from the config
(8787 by default), the address does not: every client lives on this very
computer. The Mac app, the browser extension, `hook.sh` and `start`
reach it over loopback; nothing on the network can.

## Access

Two checks at the entrance, both in `src/server.js`, in one place — a new
route needs nothing of its own:

| Check | Refused with |
|-------|--------------|
| the request did not come from `127.0.0.1` | `403` — a guard: the daemon does not listen anywhere else anyway |
| `Origin` is a web page | `403`, see below |

There is no access key any more. It existed for the phone, which reached
the daemon from the network; with the phone gone, "came from this
computer" is the whole story. An old `~/.laserbeak/token` is simply
ignored.

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

## State

### `GET /state`

Everything an app needs. Polled every 2 seconds.

```jsonc
{
  "ok": true,
  "host": "my-macbook",
  "port": 8787,
  "language": "cs",           // the language everything speaks, "auto" already resolved
  "update": {                 // is there a newer version on GitHub
    "state": "available",     // unknown | current | available | ahead | error
    "behind": 3, "more": false,
    "checkedAt": 0
  },

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
    "agent": "claude",          // claude | codex
    "label": "backend",         // from CLAUDE_LABEL
    "displayName": "Backend",   // taking the custom name into account
    "alias": "Backend",
    "project": "storefront",
    "projectPath": "/…/storefront",
    "cwd": "/…/storefront/functions",

    "status": "waiting",
    "permissionMode": "auto",   // auto | plan | acceptEdits | default; "" for Codex
    "effort": "high",           // low | medium | high | xhigh | max; "" for Codex
    "notifyEnabled": true,
    "canInput": true,           // whether prompts can be typed in
    "hosted": false,            // started by the daemon itself
    "lastBrowserUse": 0,        // ms; when this session last drove a browser
    "tmuxPane": "%3",
    "pid": 88867,

    "turns": 12,
    "turnSeconds": null,        // set while a turn is running
    "activity": {               // the last tool call of this turn; null between turns and for Codex
      "kind": "edit", "text": "editing server.js", "at": 0
    },
    "memory": {                 // RSS of the agent and everything it started (MCP servers, a browser); null if its process is unknown
      "bytes": 1550000000, "processes": 19
    },
    "lastTurnSeconds": 64.2,
    "totalWorkSeconds": 2832
  }],

  "history": [{ "ts": 0, "sid": "…", "kind": "stop", "message": "…" }],

  "island": { "show": true }  // the notch island in the Mac app — config.json, Settings → General
}
```

History messages are written in the chosen language at the moment of the
event. A permission request's original English text from Claude Code is
kept in `events.jsonl` as `detail`, not shown.

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

Accepted **from localhost only**. The body is the JSON Claude Code or
Codex passed to the hook. The response is sent before processing, so the
session never waits.

Events: `session-start`, `prompt`, `stop`, `notification`, `session-end`.
The old name `permission` is still accepted — sessions opened before the
rename still send it. Codex adds two of its own: `approval` (its
`PermissionRequest` — always "permission needed", no text to recognise)
and `interrupt` (Esc in the middle of a turn: the turn ends, no banner).

Headers: `X-Agent` (`claude` or `codex`; missing means `claude`),
`X-Claude-Label`, `X-App-Bundle`, `X-Tmux-Pane`, `X-Hook-Ppid`,
`X-Term-Program`.

---

## Actions on a session

### `POST /sessions/input`

```json
{ "sid": "…", "text": "prompt" }
```

The app no longer has a conversation view, so nothing of ours calls this
route; it stays as the primitive everything else is built on (`shot`,
`command`) and for `curl`.

Response: `{ "ok": true, "via": "tmux" }` or `"terminal"`.

`409` if the session was started without a go-between — there is no way
to type into it.

### `POST /sessions/mode`

```json
{ "sid": "…", "mode": "plan" }
```

Presses Shift+Tab and re-reads the indicator until it gets the mode you
asked for. The response includes `presses` — how many it took.

A Codex session gives `409`: its modes are an approval policy and a
sandbox, not the Shift+Tab cycle, and pressing keys there blind would
switch something else.

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
a client must not be able to send an arbitrary string as a command. An
unknown value gives `400`, a session without a go-between gives `409`.
So does `model` or `effort` to a Codex session — Codex names and picks
them differently; `compact` works in both.

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
  "size": "420×180",
  "marked": true
}
```

`marked: true` — the image carries the user's own drawing: arrows,
circles, boxes. The daemon then adds that the coloured marks are the
user's and are not on the page; otherwise a red box drawn over an
interface reads as part of the interface.

The daemon writes the image into `~/.laserbeak/shots/` and sends the
session an ordinary text prompt with the path to it — in the language
picked for Laserbeak, since these are the user's own words:

```
Look at this screenshot: /Users/…/shots/a1b2c3d4-20260821-113612.png — the
button overflows the container. This is element body > main.page >
div.hero > button.cta, text "Checkout", http://localhost:3000/checkout.
Region 420×180.
```

So it is the same input, just assembled by the daemon: Claude Code opens
the image with its own `Read`. The text is deliberately **a single line**
— every `\n` in the input is an Enter, i.e. a separate submission.

**A sequence** — several shots taken one after another ("click here, then
this opens") — comes as a `shots` array of the same objects, in order:

```json
{ "sid": "…", "shots": [
  { "image": "…", "comment": "I click here", "url": "…", "selector": "…" },
  { "image": "…", "comment": "and this should be a dialog", "marked": true }
] }
```

It becomes one prompt, still one line, with numbered items; a URL equal
to the previous item's is not repeated:

```
Look at the screenshots in order, they are one sequence; the coloured
marks on them are mine. 1) …/a1b2c3d4-20260924-113012-1.png — I click
here. … 2) …/a1b2c3d4-20260924-113012-2.png — and this should be a
dialog. …
```

Files of one sequence get `-1`, `-2`… in their names: they are written
within the same second and would otherwise overwrite each other. Every
image is decoded before the first one is written, so a broken one in the
middle leaves nothing on disk.

Response: `{ ok, via, file, files, bytes }` — `file` is the first,
`files` all of them in order.

`400` — missing `sid`/`image` (in any item), the image will not parse, or
more than 8 shots; `404` — no such session; `409` — the session was
started without a go-between (checked **before** anything is written, so
no litter is left on disk).

The body limit here is 16 MB rather than the usual 2: base64 adds a third
to the image's weight, and a sequence travels in one request. The
extension keeps its queue in `storage.session`, which holds 10 MB, so
more than that cannot arrive from it.

Screenshots sweep themselves — the last 200 or 7 days, whichever comes
first.

### `POST /sessions/interrupt`

Ctrl-C into the session: stop the work without closing it.

### `POST /sessions/spawn`

Starts `claude` in the daemon's own pseudo-terminal. The app no longer
offers it: without the conversation view such a session has no screen at
all. It stays in the API.

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
{ "path": "/…", "settings": { "color": "orange", "icon": "rocket", "silent": true } }
```

`silent: true` — banners of this project's sessions come without a
sound. An empty value (or `silent: false`) clears the setting; keys other
than these three are ignored.

### `POST /projects/forget`

Remove a project from the registry.

---

## Conversation archive

### `GET /archive`, `GET /archive/<sid>?limit=300&subagents=1`

The distilled conversations the daemon keeps after Claude Code's own
transcripts expire. The app no longer shows them; the archive is still
written, because the extension's "who drove the browser" (`lastBrowserUse`)
comes from the same reading of transcripts.

---

## Settings

### `GET /settings`

```jsonc
{
  "ok": true,
  "settings": {
    "language": "auto",                      // auto | uk | en | cs | ru | kk
    "notify": { "stop": true, "permission": true, "idle": false, "update": true },
    "sounds": { "stop": "Glass", "permission": "Funk", "idle": "Tink", "update": "Ping" },
    "updates": { "check": true },
    "island": { "show": true }
  },
  "language": "cs",                          // what "auto" resolved to
  "languages": ["auto", "uk", "en", "cs", "ru", "kk"],
  "kinds": ["stop", "permission", "idle", "update"],
  "sounds": ["Basso", "Blow", "Bottle", "…"] // /System/Library/Sounds
}
```

### `POST /settings`

Any part of the same shape: `{ "notify": { "idle": true } }`,
`{ "language": "cs" }`, `{ "sounds": { "stop": "" } }` (`""` = silent).
Written into `~/.laserbeak/config.json` next to everything else, applied
at once. The answer is the same as `GET /settings`.

Only these five groups get through, and only valid values — a port or an
`extensionId` cannot be changed this way. Anything else is `400`; a
`config.json` that does not parse is `409` and is not overwritten (it may
hold hand edits).

---

## Updates

### `GET /update`

```jsonc
{ "ok": true, "update": {
  "state": "available", "behind": 3, "more": false, "checkedAt": 0,
  "enabled": true,                 // config.updates.check
  "checking": false,
  "version": "1.0.0", "head": "ca638cf",
  "release": "White Album 1.0",    // codename from package.json + version; what the window shows
  "repo": "TimeSkipe/Laserbeak", "branch": "main",
  "url": "https://github.com/TimeSkipe/Laserbeak/commits/main",
  "error": "",
  "commits": [{ "sha": "1a2b3c4", "message": "…", "date": "…", "url": "…" }],
  "root": "/Users/…/Laserbeak",
  "commands": ["cd /Users/…/Laserbeak", "git pull --ff-only", "npm run install:all"]
} }
```

`commits` are the new ones, newest first, at most 20. `more: true` means
this copy's `HEAD` was not among the last 50 commits on GitHub.
`commands` is what the window shows to copy: the daemon does not install
anything itself.

### `POST /update/check`

Checks now and answers as `GET /update`. A check already running is
joined, not repeated.

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
  "message": "Finished\n1m 4s",
  "sound": "Glass", "appBundle": "com.jetbrains.WebStorm"
}] }
```

Only the daemon filters — the client shows everything it receives.
