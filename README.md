# Laserbeak

> This is the user-facing description. If you need to find your way
> around the code, start with [CLAUDE.md](CLAUDE.md) and the
> [docs/](docs/) folder: architecture, components, the HTTP interface
> and — most importantly — [what we learned the hard
> way](docs/decisions.md), the traps already stepped on.

A daemon plus apps that show your projects and active Claude Code
sessions — on the Mac and on the phone.

Claude Code's built-in notifications on macOS go through the terminal and
are therefore unreliable. Here the logic is moved into a separate
background process, with two SwiftUI apps sharing code on top of it.

```
Claude Code (session 1) ─┐
Claude Code (session 2) ─┼─ hooks → hook.sh → POST 127.0.0.1:8787
Claude Code (session 3) ─┘                         │
                                                   ▼
                                        laserbeak (Node, LaunchAgent)
                                        ├─ project registry (remembers all)
                                        ├─ macOS notifications
                                        └─ GET /state — 127.0.0.1 only
                                                   │
                                                   ▼
                            Laserbeak.app ──TLS past the router──► Laserbeak (iOS)
                            window + menu bar                      key from the Mac
```

The hook inside a session is a single `curl` to localhost. It answers in
milliseconds and **never blocks your work**: if the daemon is down, the
hook exits quietly.

---

## Projects are the main thing

A session does not live long: close the window and it is gone. A project
lives longer, so the main screen shows **projects**, with sessions grouped
under them:

```
▸ atlas-api                             3 sessions
    ⏸  atlas-3    needs permission
    ◐  atlas-2    working
    ○  atlas-1    idle

▸ storefront                            2 sessions
    ◐  front-1    working
    ○  front-2    idle

▸ landing                              no sessions
```

The project registry lives in `~/.laserbeak/projects.json` and **survives
a daemon restart and a reboot**. A project with nobody in it right now
stays in the list with the state "no sessions".

Sorting is by urgency: a project where Claude is waiting for permission
is always on top.

## WebStorm terminals

Besides hooks, the daemon looks straight at the process table. That shows
what hooks cannot see.

Here is how the process tree looks in WebStorm:

```
webstorm
├── zsh            ← a terminal tab
│   └── claude     ← a Claude Code session
│       └── zsh    ← the Bash tool inside the session, NOT a tab
└── zsh            ← another tab, empty
```

Only a shell whose **immediate parent** is the editor process counts as a
tab. Without that condition, the utility shells Claude Code spawns for the
Bash tool would end up in the count.

A tab counts as occupied by Claude if the `claude` process is its direct
child. So the app shows where a session is and where a terminal is merely
a terminal:

```
▸ storefront                              2 sessions
   ⌘ 3 tabs (2 with Claude, 1 without)
```

Each process's working directory comes from `lsof -d cwd` in a single
batched call for all pids at once — about 25 ms, done no more than once
every 4 seconds in the background, so `/state` stays instant.

### Sessions without notifications

Hooks only apply to sessions started **after** they were installed. A
session opened earlier is running, but the daemon knows nothing about it —
and there will be no notifications from it.

Process inspection makes such a session visible:

```
▸ docs-site                          no sessions
   ⌘ 2 tabs (2 with Claude)   🔕 2 without notifications
```

Easy to fix: restart that session.

### The project root

Claude can be started in a subfolder — say in `my-app` or `functions`
inside a single repository. If you take the session's working directory
as-is, every such subfolder becomes a separate "project", and one row in
the list turns into three.

So the root is resolved separately, in this order:

1. the project open in the IDE that contains this directory — the most
   accurate, because it is exactly what the user considers the project;
2. the nearest ancestor with `.git` or `.idea` — works with no IDE
   running;
3. the directory itself, if nothing was found.

```
~/…/storefront/my-app      →  storefront
~/…/storefront/functions   →  storefront
```

The session's working directory is still stored as-is — the only thing
that changes is which project it is counted under.

### What shows up in the list

The app only shows projects that are **open right now**. A project counts
as open if any of these holds:

- an IDE has it open (`opened="true"` in `recentProjects.xml`);
- it has a terminal tab;
- a `claude` process is alive in it;
- the daemon knows about a session in it.

The `opened="true"` flag cannot always be trusted: JetBrains leaves it in
the file after the IDE quits. So it is only honoured for IDEs whose
process is alive right now.

Closed projects **do not disappear anywhere** — the registry in
`projects.json` keeps them all along with their `settings` field. They
will come in handy when per-project settings arrive; they come through in
`/state` too, just with `isOpen: false`.

### Projects discovered on their own

If a live `claude` process is working in a directory that is not in the
registry, the project shows up in the list anyway. That way the app shows
the whole picture, even before the first hook event.

Each process is attributed to exactly one project — the deepest one
containing it. Otherwise a tab in a subdirectory would be counted twice:
for the subproject and for its parent.

## Notifications

Banners are shown by **the Laserbeak app itself** — its own icon, its own
name in Notification Center, its own group in system settings:

```
┌──────────────────────────────────┐
│ ✳  frontend                      │
│    storefront                    │
│    Done in 1m 4s · 45k tokens    │
└──────────────────────────────────┘
```

The title is the session name, the subtitle the project, and the body says
what actually happened: finished working, or permission needed. The reason
for a permission request is not put in the banner — what matters is the
fact; the full text stays in the history. On the right is the project icon
in its colour, so a banner is recognisable without reading it.

Notifications from one session are grouped together, and clicking one
opens the editor the session was started from.

**On by default.** A new session in any project notifies you about
finished work straight away — turning it off is a deliberate act, in the
session editor.

### Two different events under one hook

Claude Code's `Notification` hook fires for two unlike things:

```
"Claude needs your permission…"       a real permission request
"Claude Code needs your approval…"    plan approval
"Claude is waiting for your input"    just waiting for you to type
```

The last one arrives about a minute after an ordinary reply finishes. If
you do not tell them apart, a session wrongly looks as if Claude were
asking something, when it has simply finished and is waiting.

So the daemon looks at the text:

| What arrived | Session status | Banner |
|--------------|----------------|--------|
| permission / approval | `needs permission` | yes |
| waiting for input | `finished` | no (`notify.idle`) |

The input reminder is off by default because it duplicates the
finished-work banner. Turn `notify.idle` on if you turn `notify.stop`
off.

### How it is delivered

The daemon keeps a queue of events, and the app waits on them with a
single open request (`GET /events/wait`). The request hangs until an event
appears or for 20 seconds, then repeats. So the banner appears
**instantly** rather than at polling delay, and almost nothing crosses the
wire.

If the app is closed, the daemon sees that nobody is listening to the
queue and falls back to `terminal-notifier` — so notifications do not
vanish entirely. The log shows which path was taken:

```
· notified [stop] frontend → Laserbeak
· notified [stop] backend → terminal-notifier (app closed)
```

### Why a real signature is required

The app is signed with an Apple Development certificate rather than
ad-hoc. This is not cosmetic: with an ad-hoc signature macOS denies
notifications (`Notifications are not allowed for this application`) and
does not even show a permission prompt.

Worse, **the refusal is cached against the bundle id forever**. If you
have already hit one, a correct signature is not enough — you have to
change `PRODUCT_BUNDLE_IDENTIFIER` in `app/project.yml` so the system
creates a fresh record.

Your own certificate: `security find-identity -v -p codesigning`

## Typing from the app

The conversation view has an input field — but it does not work for every
session, and there is a technical reason for that.

### A go-between inside your own terminal

`start "name"` runs Claude **inside tmux**. Nothing changes on the
surface: the same WebStorm tab, the same look, the same keyboard input.
But now Laserbeak can type into that pane too, with `send-keys`.

This is exactly what enables prompts from the Mac app and **from the
phone** while you are away.

```
WebStorm tab
└── tmux (go-between, pane %3)
    └── claude          ← can be typed into from outside
```

tmux puts the pane's address in `TMUX_PANE`, and `hook.sh` passes it to
the daemon as a header. So the session → pane link is known as soon as the
first event arrives from it — nothing to configure.

You need `tmux`: `brew install tmux`. Without it `start` works as before,
just without outside input.

The tmux look is trimmed to invisibility — `~/.laserbeak/tmux.conf`
disables the status bar, enables the mouse and a long scrollback.

### Why it cannot work without a go-between

The stdin of a live `claude` process is a pseudo-terminal:

```
claude  0u  CHR  16,3  /dev/ttys003
```

The master end of that pseudo-terminal is held by WebStorm. Injecting
characters from outside used to be possible with the `TIOCSTI` ioctl, but
macOS removed it — the constant is not even in the system headers. So you
can only type into a terminal you created yourself.

Hence the need for a go-between that holds the pseudo-terminal itself.

### Sessions created by Laserbeak

The **＋** button in a project header starts `claude` in the daemon's own
pseudo-terminal. In such a session the input field is live:

```
▸ storefront                      ＋  🖌
   ✅  from the app
       finished · 12s
```

The identifier is generated up front and passed via `--session-id`, so the
link to hook events is known immediately — the session shows up in the
list, notifies and gets archived like any other.

The pseudo-terminal is provided by `src/pty-bridge.py`: it stitches our
pipe to the app's terminal. `/usr/bin/script` is no good for this — it
calls `tcgetattr` on its own stdin and fails with
`Operation not supported on socket` when stdin is a pipe.

The path to `claude` is found via `zsh -lic`: launchd has its own
stripped-down PATH, and with `-c` alone the shell does not read `.zshrc`,
where nvm and `~/.local/bin` are configured.

### What that gives you

```
POST /sessions/spawn      {projectPath, label, prompt}  → start
POST /sessions/input      {sid, text}                   → type
POST /sessions/interrupt  {sid}                         → Ctrl-C
POST /sessions/stop       {sid}                         → end
GET  /sessions/output/<sid>                             → raw output
```

A session started without tmux and not by the daemon answers `409` with an
explanation — and the app shows the reason instead of an input field.

`/sessions/input` is reachable from the local network too: that is how the
phone types. Which means anyone on your Wi-Fi could send a prompt into a
session — acceptable for a home network; on a shared one set
`"bindHost": "127.0.0.1"`.

## Show the session instead of describing it

A session can look at a browser, but explaining **where** exactly
something is broken is exhausting: "that button, at the bottom, under the
form, on the left". So there is an extension for Chrome (and any
Chromium — Brave, Arc): you drag a region with the mouse, write one
sentence, and the session gets the picture.

```
⌘⇧E  →  drag a region  →  "the button overflows the container"  →  Enter
```

Clicking the icon and right-clicking the page do the same. The keyboard
shortcut is not decoration here: the difference between three steps and
five is the difference between using this daily and not.

### The selector travels with the picture

This is half the point. The extension knows which element was under the
region and sends it along with the shot:

```
Look at this screenshot: ~/.laserbeak/shots/a1b2c3d4-20260821-113612.png —
the button overflows the container. This is element
body > main.page > div.hero > button.cta, text "Checkout",
http://localhost:3000/checkout. Region 420×180.
```

The picture says **what** is wrong; the selector says **where** it is in
the code — the session greps it and lands in the right file immediately.

The selector is verified against the page itself: if it matches more than
one element, the extension refines the path until exactly one is left.
Across 140 elements on GitHub and react.dev, all 140 came out exact.
Hashed classes (`sc-a1b2c3d`, `css-1x2y3z`) are discarded — you could
never grep them anyway.

### Where exactly it goes

Claude in Chrome puts the tabs of one conversation into their own **tab
group**, so "which tab belongs to which session" is a fact from the
browser's API, not a guess. The session is chosen once per group and
remembered after that:

```
┌─────────────────────────────────────────┐
│  → front-1 · storefront            ▾    │
├─────────────────────────────────────────┤
│  the button overflows the container     │
│                              Enter ↵    │
└─────────────────────────────────────────┘
```

The image reaches the session **as text** — a path to a file which Claude
Code opens with its own `Read`. No separate channel for images was needed.

### Worth knowing up front

Tested on a live site, and three things are worth keeping in mind.

**Only the visible area is captured.** A list of 57 cards yielded four in
frame — the rest were below the fold. That is not a limit of our code but
how a tab capture works: the session answers about what it can see.

**Inside a `<canvas>` the selector is powerless.** A MapLibre map is one
canvas with no DOM inside, so nothing more precise than
`canvas.maplibregl-canvas` exists. For maps and charts what works is the
picture itself plus the page address, which is usually where the
coordinates live: `#12.64/50.0875/14.4213`.

**The element's text arrives separately from the picture.** A string of
its contents travels with the shot — on a listing page that was price,
area and address. So part of the data reaches the session as **exact
text** rather than as recognition from a JPEG: for interfaces full of
numbers that is noticeably more reliable.

Large regions are sent as JPEG automatically — a `1594×1544` shot would
weigh several megabytes as PNG. The text on it stays perfectly readable.

### Languages

Ukrainian, English and Czech. The choice is split in two, because the
text comes from two different places.

**Banners and API errors are written by Laserbeak itself** — it is the
one assembling them, and in the `terminal-notifier` fallback there is no
app involved at all. So the language is chosen once, at install time:

```bash
LASERBEAK_LANG=cs npm run install:all
```

Without it you get `auto` — whatever the system is set to. It can be
changed later in `~/.laserbeak/config.json` (`"language"`, re-read on the
fly), or for a single run: `LASERBEAK_LANG=en npm start`.

**The apps take the language from the device.** A phone set to English
shows an English screen with nothing to configure — the strings live in a
String Catalog, and iOS and macOS pick the right one themselves. Which
also means the Mac can be in Ukrainian while the phone is in English.

To try another language without touching system settings:

```bash
defaults write com.laserbeak.desktop AppleLanguages -array en
# back to normal:
defaults delete com.laserbeak.desktop AppleLanguages
```

Log files stay in one language deliberately: hunting for "session not
found" in three languages inside `daemon.log` would be worse than in one.

---

## Installation

```bash
npm run extension    # copies the folder path to the clipboard
```

Then `chrome://extensions` (in Brave, `brave://extensions`) → "Developer
mode" → "Load unpacked" → ⌘V. It is not in the Web Store, so this is done
by hand.

Install it in **the browser your sessions drive** — the one where Claude
in Chrome lives. Easy to check: whichever browser holds
`NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json`
is the one you want. Any Chromium will do — Chrome, Brave, Arc; the code
is identical, only the profile directory differs.

The extension asks for exactly two permissions: `activeTab` — access to
the tab you just acted in, and only for now — and requests to
`127.0.0.1:8787`. It never sees the rest of your pages.

### About localhost security

Now that a browser talks to the daemon, trusting localhost stopped being
free: foreign code ends up in a tab by itself. So the daemon inspects
`Origin` — a page from the network gets `403` even from localhost. It
cannot forge `Origin`; the browser sets it.

Screenshots live in `~/.laserbeak/shots/` and sweep themselves: the last
200 or 7 days.

---

## Permission mode

The session row shows the current mode, and you can switch it right
there:

| Mode | What it means |
|------|---------------|
| auto | Claude decides for itself what is safe to run |
| plan | plan first, actions only after approval |
| accept edits | file edits without asking |
| default | asks permission for every action |

### Where the current mode comes from

The transcript contains
`{"type":"permission-mode","permissionMode":"auto"}` records, but they are
written **on every user prompt, not on every mode change**. So that is the
mode as of the last message, not the current one. It is easy to get burned
by this: switching works, and the check cannot see it.

The live source is the Claude Code interface itself, which shows the mode
in its bottom status line:

```
⏵⏵ auto mode on (shift+tab to cycle)
⏸ plan mode on (shift+tab to cycle)
⏸ manual mode on
```

For tmux sessions this is read via `capture-pane`, for our own from the
terminal output. The transcript remains the fallback for when a session
has not drawn anything yet. The reading is cached for 3 seconds.

### How switching works

With Shift+Tab, which cycles. The cycle order is not documented anywhere
and could change with a release, so the daemon **does not assume it**: it
presses Shift+Tab and re-reads the indicator each time until it gets the
mode it wants.

```
auto → plan     3 presses
plan → default  2 presses
default → auto  3 presses
```

This approach adapts itself if Anthropic changes the order.

## When a session dies

The `SessionEnd` hook arrives on a normal exit, but if you kill the tab or
close the WebStorm window it never fires — and the session would hang in
the list forever.

So the daemon **checks liveness itself every half minute**: for tmux
sessions that means the pane exists, for its own the state of the child
process. The check is cheap and exact, so it is done often.

Verified with a hard `kill -9`, after which no hook fires:

```
· collected a dead session the hard way (73bbafe5)
```

### The Refresh button

Half a minute is not long, but when you have just closed a tab and are
staring at the window, you would rather not wait. The ↻ button in the
status bar (or **⌘R**) does everything at once:

- inspect processes and terminal tabs;
- check the liveness of every session;
- ingest new transcript bytes;
- reset the mode cache.

```
before pressing:  Claude, MMM, button
after:            Claude, MMM          (the dead one collected)
```

The same check as on the timer — just on demand (`POST /refresh`).

Sessions themselves also live in `~/.laserbeak/sessions-live.json`: the
daemon only learns about a session from a hook, so restarting mid-work
would make it forget everything open — and the next event may be a long
time coming, because the session is simply waiting for you. The same
watchdog clears dead records from there.

## Conversation archive

Claude Code keeps a transcript of every session, but **removes it after
about 30 days**. On this machine that was immediately visible: 518 MB, 758
files, the oldest exactly 31 days old. So without an archive the
conversation simply disappears.

The **💬** button in a session row opens the saved conversation with
search.

### An active session's history, live

The **💬** button opens the conversation, and for a working session it
updates itself, with no action from you:

```
frontend  ● live
storefront · 300 of 595 messages
```

The daemon ingests the transcript every two seconds rather than only on
hook events — otherwise the history would lag mid-reply, because the
`stop` hook only arrives at the end of a turn.

Two groups are ingested:

1. sessions the daemon knows about from hooks;
2. every transcript in the index modified in the last 10 minutes.

The second saves the case where the daemon was restarted mid-work: the
sessions are not in memory yet, but the conversation ought to keep
growing.

Scrolling sticks to the bottom until you scroll up yourself or start
searching. For long sessions a tail of 300 messages is fetched — the rest
behind a "Full history" button, so megabytes are not pulled every two
seconds.

### What gets stored

Not a raw copy but a distillation: user messages, Claude's replies and the
names of the tools used. `tool_result` contents and thinking signatures
are dropped — they are exactly what inflates the file.

```
raw transcript :   4.59 MB
distilled      :   0.09 MB   (549 messages)
difference     :   49×
```

Reads are incremental, from a stored offset, with deduplication by `uuid`
— the same record occurs in a transcript more than once.

### Picking up what is still on disk

The daemon archives from the moment it starts. Everything already on disk
that has not yet vanished is picked up by a separate script:

```bash
launchctl bootout gui/$(id -u)/com.laserbeak.daemon
node scripts/archive-import.js
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.laserbeak.daemon.plist
```

The daemon has to be stopped: it holds the archive index in memory and
would overwrite the script's work with its own copy. The script checks for
this and refuses to run in parallel.

Dry run: `node scripts/archive-import.js --dry`

On this machine the import took 2 seconds: 23 sessions, 16,885 messages,
**223 MB of transcripts → 7 MB of archive**.

## Tokens and session time

The **ⓘ** button in a session row shows the details:

```
Time
  Total working time          47m 12s
  Turns                             56
  Last turn                     1m 4s
  Session open                 3h 20m

Tokens
  Total                     48,317,159
  Fresh context                    490
  Cache writes                 287,878
  Cache reads               47,188,033
  Output                       206,604
      of which thinking         46,543
  Replies                          247
  Model                  claude-opus-5
```

Total working time is the sum of all turns; it accumulates until the
session is closed for good.

### Where the numbers come from

Claude Code keeps a session transcript in JSONL, and the path to it
arrives with every hook (`transcript_path`). Every `assistant` record
carries the full `usage` from the API — these are actual numbers, not an
estimate.

Two subtleties make a naive count lie:

1. **Duplicates.** The same assistant record lands in the file several
   times (the copies are identical). Without deduplication by
   `message.id` the sum is inflated roughly one-and-a-half times — 73.9M
   instead of 48.3M on a real file.
2. **Size.** The transcript grows constantly. So only new bytes are read
   from a stored offset, rather than the whole file each time. That is
   what lets the counter update even mid-turn.

How much a particular turn ate is visible in the banner too:

```
✅ storefront
Done in 1m 4s · 45k tokens
```

### Model, effort and context compaction

The slider in the conversation header opens three things:

| What | Values |
|------|--------|
| **Model** | Opus 5, Fable 5, Sonnet 5, Haiku 4.5 |
| **Effort** | low, medium, high, xhigh, max |
| **Compact context** | the same as `/compact` |

Technically these are slash commands sent into the session by the same
route as ordinary prompts. But the endpoint is separate and has an
allow-list: the phone must not be able to send an arbitrary string as a
command.

**Model and effort are global.** Claude Code saves the choice as the
default for new sessions, and that is its behaviour, not ours: the model
picker says as much — "Enter to set as default · s to use this session
only". So the effort menu is labelled "default for new sessions".

The current model comes from the transcript — a fact about what the
session last replied with. The effort level is not written there, so it is
read from `~/.claude/settings.json`.

> Reading it from the Claude Code status line did not work out, though it
> looked like it might: `● high · /effort` is only shown to a new session
> and disappears as soon as any work happens in it.

### Markdown

Claude's replies are markdown, and showing them raw meant reading
`## Heading` and `| a | b |` with your own eyes. So the app renders it
itself: headings, lists, tables, code blocks, quotes, inline code.

We did not take a library for the same reason as with the Lucide icons —
one dependency for the sake of markdown is not worth it. The feature set
was decided not by eye but by counting across 2,402 real replies: inline
code in 56%, bold in 47%, lists in 12%, tables in 10%, headings in 9%.

Tables and code blocks scroll sideways — otherwise they run off the screen
on a phone. Parsing costs 0.05 ms per reply, i.e. nothing.

### What the conversation looks like

A Claude Code session is mostly tool calls, and drawing each one as a
bubble labelled "Claude" turns the feed into a list of the word "Bash".
So:

- a message with no text, only tools, becomes a thin grey line with no
  header;
- identical tools are collapsed: `Bash ×3 · Read`;
- next to a reply you can see **how long it took**.

The daemon measures the time from your message to the end of the turn and
attaches it to the last reply containing text — otherwise the number would
land on a thin line where nobody can see it. On real archives 262 turns
out of 286 get a time; the rest are turns interrupted midway.

### Per-session settings

The pencil on the right of a session row opens the editor:

- **Custom name** — replaces the label from `CLAUDE_LABEL`. An empty field
  restores the original.
- **Notifications for this session** — a banner switch for that session
  alone.

Both are applied **on the daemon side**, so they take effect globally: in
the Mac window, in the menu bar, on the phone and in the banners
themselves. A session with notifications off is marked with a struck-out
bell.

Stored in `~/.laserbeak/sessions.json`, and survives a restart:

```
· notified [stop] Frontend API
· silent [stop] backend: notifications off for this session
```

### Project colour and icon

The brush in a project header opens a colour picker (8 options) and an
icon picker (16 from the Lucide set). A project becomes recognisable at a
glance:

```
🚀 storefront                             2 sessions     ← orange rocket
🗄 atlas-api                              3 sessions     ← teal database
```

The colour name is stored rather than its hex code: system colours adapt
to light and dark themes themselves, and the name stays readable in
`projects.json` and works identically on the Mac and the phone.

The same colour and icon end up in the notification banner.

These settings live in the registry's `settings` field, so they are kept
for every project — even closed ones that are not in the list. An empty
value means "as default" and is not stored in the file.

#### Lucide icons without a library

SwiftUI cannot do SVG. Rather than pulling in a dependency, the geometry
of sixteen icons is converted once into SwiftUI `Path` commands by
`scripts/make-lucide.py`, with the result in
`app/Shared/LucideIcons.swift`.

The script parses the `d` attribute in full: relative coordinates, smooth
curves, and elliptical arcs (`A`) converted to cubic Béziers, because
SwiftUI has no arc with the same parameters. Circles, ellipses and
polylines are supported too.

To change the set, edit the `ICONS` list in the script and run:

```bash
python3 scripts/make-lucide.py && npm run build:app
```

---

## Installation

There is no downloadable binary, and that is deliberate — see below.
Clone the repository and build on your own machine:

```bash
git clone https://github.com/TimeSkipe/Laserbeak.git
cd Laserbeak
npm run install:all
```

The script installs `terminal-notifier`, builds the `.app`, puts it in
`/Applications`, registers two LaunchAgents (autostart at login) and
writes the hooks into `~/.claude/settings.json` — with a backup, leaving
other settings alone.

Hooks take effect in **new** Claude Code sessions. To remove everything:
`npm run uninstall`

**Clone somewhere permanent.** The daemon runs from the checkout — the
LaunchAgent points straight at `src/daemon.js` inside it. Move or delete
the folder and the daemon stops coming back at login, with nothing in the
interface explaining why. `~/Projects` is fine; `~/Downloads` is asking
for trouble.

The build leaves about 100 MB in `build/`. It is only intermediate output
— safe to delete once the app is in `/Applications`, and it regenerates
on the next build.

Requirements: Node 18+, Xcode, `xcodegen` (`brew install xcodegen`), and a
signing certificate — see the next section.

### You need your own signing certificate

This is the one requirement that cannot be skipped, and it costs nothing.

macOS refuses notifications to an ad-hoc-signed app
(`Notifications are not allowed for this application`) and does not even
show a permission prompt — so the whole point of the project evaporates.
A real **Apple Development** certificate fixes it, and a free Apple ID
gives you one:

```
Xcode → Settings → Accounts → "+" → your Apple ID
      → Manage Certificates → "+" → Apple Development
```

That is all. The build finds the certificate in your keychain by itself
and takes the Team ID from it (`scripts/team-id.sh`); nothing has to be
edited. If you have several teams, pick one explicitly:

```bash
LASERBEAK_TEAM=XXXXXXXXXX npm run install:all
```

If no certificate is found, the build stops and prints these same
instructions rather than producing a silently broken app.

### Why there is no ready-made installer

Because a downloaded binary would be worse for you, not better. An app
signed with someone else's Apple Development certificate is not notarised
for your machine: macOS greets it with "cannot verify the developer", and
you end up clicking through Gatekeeper warnings. Distributing it properly
needs a paid Apple Developer Program membership ($99/year) for `Developer
ID Application` + `Developer ID Installer` certificates and notarisation.

Building locally sidesteps all of it: the app is signed with *your*
certificate, for *your* machine, and Gatekeeper has no objection.

**The simplest path is to let Claude Code do it.** Clone the repository,
open it in Claude Code and ask it to install the project — it will check
the prerequisites, obtain the Team ID from your keychain, build, register
the background services and wire up the hooks. If a certificate is
missing, it will tell you exactly which buttons to press in Xcode.

### If you have no iPhone

The phone app is a bonus, not the core. Everything else — the daemon,
the Mac app, notifications, typing into sessions, the archive and the
browser extension — works exactly the same without it.

Concretely, this saves you the largest download of all: **you do not need
the iOS platform** (`xcodebuild -downloadPlatform iOS`, ~8.5 GB). The
macOS and iOS targets are separate schemes, and `npm run build:app`
builds only the Mac one. Skip `scripts/install-phone.sh` and nothing else
changes.

You still need Xcode itself, for the reasons above: the free certificate
is issued through it, and the project is built with `xcodebuild`.

There is no Android app, and there will not be one without rewriting the
client — the apps are SwiftUI, shared between macOS and iOS precisely
because those two speak the same language. An Android phone can reach the
daemon over HTTP, but there is no interface on the other end to show it,
only JSON.

### What Claude Code can and cannot do for you

Most of the setup is scriptable, and Claude Code will handle it: install
`tmux` and `terminal-notifier` via Homebrew, build and sign the app with
your certificate, register both LaunchAgents, patch the hooks into
`~/.claude/settings.json` and verify the daemon answers.

Three things it cannot do, because they are GUI actions behind your Apple
ID or inside browser-internal pages:

1. **Install Xcode**, if you do not have it. It comes from the App Store
   and is well over 10 GB.
2. **Create the signing certificate.** Signing in with an Apple ID
   happens in Xcode's own window, and nobody can type your password for
   you. The clicks are listed above; it takes a minute.
3. **Load the browser extension.** `chrome://extensions` is closed to
   every extension, including the one Claude Code drives the browser
   with — so "Developer mode" → "Load unpacked" is yours to click.
   `npm run extension` copies the folder path to the clipboard first.

macOS will also ask for notification permission the first time a banner
fires — that is a system prompt, and it only appears once.

---

## The Mac app

`/Applications/Laserbeak.app` is an agent app: it lives in the menu bar
and appears neither in the Dock nor in ⌘Tab. Roughly like Docker.

That is by design: it holds the only channel to the phone, so it has to be
running at all times. A Dock icon would merely pretend the app is "open"
and invite a ⌘Q.

**The window is opened from the menu bar** — "Open window". The close
button just closes it; the app keeps working. To quit for real, use "Quit"
in the same place.

An agent app has no menu bar of its own, so ⌘Q does nothing. ⌘W was kept —
the window closes the usual way.

The menu bar icon:

| Icon | What it means |
|------|---------------|
| `○ 3` | 3 sessions, all idle |
| `◐ 2` | something is working right now |
| `⏸ 1` | Claude is waiting for permission |
| `⚠︎` | the daemon is not responding |

---

## The phone app

The same set as on the Mac: projects with colours and icons, sessions, the
conversation with an input field, the mode switcher, the refresh button.
It is not a separate app — every screen lives in `app/Shared/` and is
compiled for both platforms.

### Installation

```bash
bash scripts/install-phone.sh
```

The script finds the iPhone connected by cable, builds and installs.

Once, before that, you need to download the iOS platform:

```bash
xcodebuild -downloadPlatform iOS
```

Without it the device shows up as `connected (no DDI)` and the build fails
with `iOS 26.5 is not installed`.

On first launch iOS will ask for **local network permission** — without it
the phone will not find the laptop at all, neither over the direct channel
nor over HTTP.

> **About a free Apple ID:** such a signature lasts 7 days, after which the
> app has to be reinstalled. A paid Apple Developer account ($99/year)
> removes the limit.

### Pairing: scan a code once

On the Mac there is a QR icon in the status bar. The code carries the
**access key**, without which the daemon gives out nothing. The key goes
into the phone's Keychain and is never asked for again.

The same key becomes the password of the encrypted connection, so the
secret is transferred exactly once: from screen to camera.

### A direct channel, past the router

The phone and the Mac find each other over Bluetooth, and the data flows
over AWDL — direct Wi-Fi between devices. This is what AirDrop and Handoff
use, so no shared network is needed at all.

The channel is held by the Mac app: the daemon is written in Node, while
Network.framework is Apple's. The app already talks to the daemon over
`127.0.0.1`.

```
phone ──TLS──► Laserbeak.app ──HTTP──► 127.0.0.1:8787
```

Encryption is TLS with a pre-shared key. There are no certificates and
none are needed: you carried the secret with your eyes. A wrong password
fails the handshake itself.

**The daemon is not on the network at all in this setup.** That is the
whole point of the scheme: there is no open port on the Wi-Fi.

The icon in the top left tells you what is in use: a laptop with a lock
means the direct channel, a plain laptop means the HTTP fallback (if you
enabled it).

### What if the Mac app crashes

Then the phone goes blind — which is why that must not happen. The daemon
checks every ten seconds whether the app is reachable and brings it back:
about a minute from crash to recovery.

What is checked is not a row in the process table (a process can hang
around doing nothing) but whether the app is holding an open notification
request.

"Quit" in the menu bar still works for real: a deliberate quit leaves a
marker, and while it is there the daemon leaves the app alone. The marker
is removed on the next launch — including at login.

### If you want it to work without the app

Put this in `~/.laserbeak/config.json`:

```jsonc
"bindHost": "0.0.0.0"
```

That enables the fallback: the phone talks to the daemon directly over
HTTP with the key in a header, and works even with the app closed. The
price is that traffic on the local network is in the clear, and it only
works on the same network as the laptop. The phone picks its own path and
switches to the direct one as soon as it appears.

The direct channel's speed, measured on this very setup: a 12 KB state
snapshot in 2 ms, a 1.9 MB session archive in 66 ms.

> **Why not plain Bluetooth.** CoreBluetooth gives ~180-byte packets and a
> few KB/s. State updates every two seconds and archives weigh megabytes —
> over BLE that would take minutes. AWDL gives the same convenience with
> no speed penalty.

### What you can do from the phone

| Action | Works |
|--------|-------|
| view projects and sessions | yes |
| read the conversation live | yes |
| type prompts into a session | yes |
| change the permission mode | yes |
| change a project's colour and icon | yes |
| rename sessions, mute their notifications | yes |
| start a new session | no, Mac only |

Starting a process from the network is deliberately kept local — it is the
only thing that creates something new on the computer.

Verified over both paths. Over the direct channel:

```
GET  /state              → 200, 11.7 KB, 5 sessions        in 2 ms
GET  /archive/<sid>      → 200, 1.86 MB, 2391 messages     in 66 ms
POST /sessions/settings  → 200
```

And that the daemon really is invisible on the network:

```
curl http://192.168.0.108:8787/state   → connection refused
lsof -iTCP:8787 -sTCP:LISTEN           → TCP 127.0.0.1:8787 (LISTEN)
```

And with the fallback enabled (`bindHost: 0.0.0.0`), the key is checked
like this:

```
with the key                      → 200
without the key                   → 401
with a wrong key of equal length  → 401
```

---

## Launching from WebStorm

`__CFBundleIdentifier` is a variable macOS sets itself: the bundle id of
the app the terminal was launched from. In a WebStorm terminal it equals
`com.jetbrains.WebStorm`, whereas the familiar `TERM_PROGRAM` there is
**empty**.

That is why clicking a banner opens WebStorm specifically, rather than
some terminal. The same bundle id is remembered in the project registry —
so that projects can later be opened in their own editor.

---

## Rules

`~/.laserbeak/config.json`, **re-read on the fly** — save the file and the
rules are already new.

```jsonc
{
  "port": 8787,

  // 127.0.0.1 — the daemon is not on the network at all. The phone
  // travels over a direct encrypted channel through the Mac app.
  // "0.0.0.0" — also enable the HTTP fallback: works even with the app
  // closed, but traffic on the network will be in the clear.
  "bindHost": "127.0.0.1",

  // The name the laptop appears under in the phone app
  "serviceName": "my-macbook",

  // The extension allowed to talk to the daemon. Empty means any
  // extension; pages from the network are refused either way.
  "extensionId": "bcibihhnnjblcbgehfemebkkdcnhjmnf",

  "notify": {
    "stop": true,        // Claude finished a turn
    "permission": true   // waiting for permission / input
  },

  // System sounds from /System/Library/Sounds. "" = silent.
  "sounds": { "stop": "Glass", "permission": "Funk" },

  "historySize": 200
}
```

### About security

Anything not coming from this computer must bring a key:

```
Authorization: Bearer <key>
```

The key is created on first run and lives in `~/.laserbeak/token` with
mode `0600`. The phone gets it from a QR code — that is the only way to
connect. Without a key the daemon answers `401` and gives out nothing.

Requests from `127.0.0.1` need no key: only someone already sitting at
this computer can make them. Hook events (`POST /hook/*`), starting
sessions and the key itself are available **only** from there — even with
a key.

By default the daemon listens on `127.0.0.1` **only** — there is no open
port on the network. The phone travels over an encrypted channel through
the Mac app. The key is still needed: it serves as that encryption's
password.

Since a browser extension also talks to the daemon, trusting localhost
stopped being free: a `POST` from a page arrives without a preflight, i.e.
it executes, even though nobody sees the response. So the daemon inspects
`Origin` and refuses pages from the network.

The HTTP fallback is enabled with `"bindHost": "0.0.0.0"` — the phone then
works with the app closed too, but traffic on the local network is in the
clear.

To rotate the key, use the "New key" button in the pairing window. After
that every phone has to be paired again.

---

## Session labels

A function in `~/.zshrc` passes the label to the daemon:

```bash
start() {
  local label="$1"
  ...
  CLAUDE_LABEL="$label" claude "${@:2}"
}
```

`start "backend"` → the label `backend` appears in the banner, in the Mac
window and on the phone. Without a label, the first 6 characters of the
session id are used.

---

## Layout

```
src/            the Node daemon
  daemon.js       entry point
  server.js       HTTP API
  events.js       hook event handling
  projects.js     project registry (survives restarts)
  state.js        sessions, history, per-project rollups
  sessionSettings.js  custom session names and notification switches
  tokens.js       token accounting from the session transcript
  archive.js      conversation archive (transcripts live only 30 days)
  shots.js        region screenshots from the browser → prompt into a session
  roots.js        resolving the project root from a working directory
  outbox.js       notification queue for the app (long-poll)
  auth.js         access key: without it the daemon gives out nothing
  appguard.js     keeps the Mac app alive
  inspect.js      process inspection: terminal tabs and live claude processes
  notify.js       macOS notifications
  bonjour.js      local network advertisement
  config.js       config, re-read on the fly

app/
  project.yml     Xcode project description (xcodegen); .xcodeproj not in git
  Shared/         code shared by both platforms
    Models.swift       mirror of the JSON from /state
    DaemonClient.swift polling the daemon; unaware of which path data takes
    Transport.swift    the path: protocol + HTTP with the key
    PeerLink.swift     direct encrypted channel (TLS-PSK over AWDL)
    Pairing.swift      key in the Keychain, laptop address
    Discovery.swift    finding the laptop: direct channel and fallback address
    Views.swift        screens, including ProjectsView
  macOS/          window + menu bar + listener for the phone
  iOS/            navigation + choosing the path to the laptop
    LucideIcons.swift  Lucide icons (generated by scripts/make-lucide.py)
    Palette.swift      project colours
  Resources/      app icon (generated by scripts/make-icon.py)

extension/      browser extension: drag a region → send it to a session
  manifest.json   MV3; the id is stable because it carries a public key
  background.js   capture, cropping, talking to the daemon
  overlay.js      frame, input field, element selector (Shadow DOM)
  popup.js        settings window

hooks/hook.sh   the session → daemon bridge
scripts/        install, build, icons, settings.json patching
```

To add something platform-specific, put it in `macOS/` or `iOS/`.
Anything shared goes in `Shared/` and works on both at once.

---

## Commands

```bash
npm run logs        # tail the daemon log
npm run state       # current state as JSON
npm run discover    # who is advertising on the network
npm run restart     # restart the daemon
npm run build:app   # rebuild the macOS app
npm run extension   # copy the extension folder path to the clipboard
npm run xcode       # open the project in Xcode
```

To regenerate the icons from a different image:

```bash
python3 scripts/make-icon.py path/to/image.png && npm run build:app
```

---

## HTTP API

Full description in [docs/api.md](docs/api.md). Access in brief:

| Method | Path | Access |
|--------|------|--------|
| POST | `/hook/<event>` | 127.0.0.1 only |
| POST | `/sessions/spawn` | 127.0.0.1 only |
| GET | `/auth/token` | 127.0.0.1 only |
| POST | `/auth/rotate` | 127.0.0.1 only |
| GET | `/state`, `/health` | network, with key* |
| POST | `/refresh` | network, with key |
| POST | `/sessions/input`, `/mode`, `/interrupt`, `/stop`, `/forget` | network, with key |
| POST | `/sessions/shot` | network, with key |
| POST | `/sessions/settings`, `/projects/settings`, `/projects/forget` | network, with key |
| GET | `/archive`, `/archive/<sid>` | network, with key |
| GET | `/events/wait` | network, with key |

\* "network" is only available when the HTTP fallback is enabled
(`bindHost: 0.0.0.0`). By default the daemon listens on `127.0.0.1` only,
and the phone reaches it through the Mac app.

The key goes in an `Authorization: Bearer <key>` header. Without it,
anything not from `127.0.0.1` gets a `401`.

Events: `session-start`, `prompt`, `stop`, `notification`, `session-end`.

---

## What's next

- **Open a project in its editor** — the bundle id is already remembered.
- **Push to the phone** — right now the phone only polls; notifications on
  a locked screen would need APNs or a connection that survives in the
  background. The direct channel is already bidirectional, so the first
  step is done.
- **Quiet rules** — do not notify when you are looking at that very
  project.
- **Capturing a longer page** — only the visible area is taken today;
  scrolling and stitching would give the whole list rather than the first
  screen.
- **Guessing the session for you** — the extension sees when a tab group
  appeared and the daemon knows which session was working then; that is
  enough to propose the recipient without asking even the first time.
