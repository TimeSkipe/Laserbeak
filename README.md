# Laserbeak

> This is the user-facing description. If you need to find your way
> around the code, start with [CLAUDE.md](CLAUDE.md) and the
> [docs/](docs/) folder: architecture, components, the HTTP interface
> and — most importantly — [what we learned the hard
> way](docs/decisions.md), the traps already stepped on.

A daemon plus a Mac app that show your projects and active Claude Code
and Codex sessions, notify you about them and let you steer them —
permission mode, model, effort, context compaction. Plus a browser
extension that sends a session a screenshot of a region of a page, the
`start`/`stop` commands, and a mod that draws Claude's replies as cards.

Claude Code's built-in notifications on macOS go through the terminal and
are therefore unreliable. Here the logic is moved into a separate
background process, with a SwiftUI app on top of it.

```
Claude Code (session 1) ─┐
Claude Code (session 2) ─┼─ hooks → hook.sh → POST 127.0.0.1:8787
Codex       (session 3) ─┘                         │
                                                   ▼
                                        laserbeak (Node, LaunchAgent)
                                        ├─ project registry (remembers all)
                                        ├─ macOS notifications
                                        ├─ settings, update check
                                        └─ HTTP on 127.0.0.1 only
                                                   │
                                     ┌─────────────┴─────────────┐
                                     ▼                           ▼
                              Laserbeak.app               browser extension
                              window + menu bar           region → session
```

The hook inside a session is a single `curl` to localhost. It answers in
milliseconds and **never blocks your work**: if the daemon is down, the
hook exits quietly.

Ukrainian, English, Czech, Russian and Kazakh — one language for
everything, picked at install time and changeable in the app.

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
│ ✳  frontend                 [🚀✓]│
│    storefront                    │
│    Finished                      │
│    1m 4s                         │
└──────────────────────────────────┘
```

The title is the session name, the subtitle the project, and the body says
what actually happened: finished working, or permission needed. The reason
for a permission request is not put in the banner — what matters is the
fact; the full text stays in the history. On the right is the project icon
in its colour with the event in its corner — a green tick for finished
work, an orange hand for permission, an hourglass for the input reminder
— so a banner says whose and what without being read.

Notifications from one session are grouped together, and clicking one
opens the editor the session was started from.

**On by default.** A new session in any project notifies you about
finished work straight away. Which events show a banner, and with which
of the standard macOS sounds, is set in the app: Settings →
Notifications, with a ▶ to hear each sound. A whole project can be made
quiet with the speaker on its card — banners still come, without sound.
A single session is muted in its own menu (⋯ → Name and notifications),
and that beats the general rule.

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
finished-work banner. Turn it on in Settings → Notifications if you turn
the finished-work banner off.

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

## Steering a session from outside

The app does not chat with a session — that went away on purpose; the
terminal is where you talk to Claude. What the app and the extension do
is press keys for you: switch the permission mode (Shift+Tab), send
`/model`, `/effort`, `/compact`, Ctrl-C, and the screenshot prompt from
the browser. That only works for a session started with `start`.

### A go-between inside your own terminal

`start "name"` runs Claude **inside tmux**. Nothing changes on the
surface: the same WebStorm tab, the same look, the same keyboard input.
But now Laserbeak can type into that pane too, with `send-keys`.

```
WebStorm tab
└── tmux (go-between, pane %3)
    └── claude          ← can be typed into from outside
```

tmux puts the pane's address in `TMUX_PANE`, and `hook.sh` passes it to
the daemon as a header. So the session → pane link is known as soon as the
first event arrives from it — nothing to configure.

You need `tmux` (`brew install tmux`; the installer does it). Without it
`start` works as before, just without outside input. The tmux look is
trimmed to invisibility — `shell/tmux.conf` disables the status bar,
enables the mouse and a long scrollback.

### Why it cannot work without a go-between

The stdin of a live `claude` process is a pseudo-terminal:

```
claude  0u  CHR  16,3  /dev/ttys003
```

The master end of that pseudo-terminal is held by WebStorm. Injecting
characters from outside used to be possible with the `TIOCSTI` ioctl, but
macOS removed it — the constant is not even in the system headers. So you
can only type into a terminal you created yourself.

A session started without `start` says so in its details ("Input from
outside: no"), and its menu simply has no model or effort items.

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

### Draw on it

Some things are easier to show than to say: "this box wider, the button
over here". The preview has a **Mark up** button (clicking the preview
does the same): the shot opens over the page, enlarged if the region was
small, and you draw on it — freehand, an arrow, a circle, a rectangle, in
red, yellow, green, blue, black or white.

```
Shift   a perfect circle, a square, an arrow at 45°
⌘Z      undo the last shape
Enter   done — back to the comment field
Esc     cancel what you drew this time
```

Reopening the editor brings back the same shapes, still editable. The
session is told the coloured marks are yours, so it does not go looking
for a red box in the code.

### Several shots, in order

"First I click here — then this opens, and it should be a dialog
instead." **Next shot** under the preview puts the current shot aside
with its comment, and the frame comes right back for the next one; the
page scrolls under it. Thumbnails of the shots so far run along the card,
and Enter sends them all as one numbered prompt:

```
Look at the screenshots in order, they are one sequence.
1) …/a1b2c3d4-20260924-113012-1.png — I click here. …
2) …/a1b2c3d4-20260924-113012-2.png — and instead of this banner there
   should be a dialog. …
```

The next step is on another page? Press Esc — the shots taken so far
stay queued — go there, and ⌘⇧E carries on with the next number. Esc only
ever drops the shot in front of you; one already queued goes with the ×
on its thumbnail. Up to 8 shots per sequence.

### Where exactly it goes

You never pick it. When Claude in Chrome opens a tab group, the extension
asks the daemon who has just been driving a browser — and the daemon
knows, because it sees `mcp__claude-in-chrome__*` calls in the session
transcripts. The group is bound silently, before you capture anything.

If that trail is missing (the session drove the browser some other way),
it falls back to "exactly one session is working", and only then asks.

The binding is remembered per tab group, so it survives restarts:

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

The extension speaks the language picked for Laserbeak — it asks the
daemon, so a change in the app reaches the next capture. If the daemon
is down, it uses the last language it knew, and failing that the
browser's. Its settings window shows the current language; it is changed
in the app, not there.

What cannot follow: the extension's name and description and the
shortcut's description in `chrome://extensions` — the browser resolves
those itself, in its own language.

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

## Permission mode

The session row shows the current mode as a chip, and clicking it
switches the mode:

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
window's toolbar (or **⌘R**) does everything at once:

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
about 30 days**. The daemon keeps a distilled copy in
`~/.laserbeak/archive/`: user messages, Claude's replies and the names
of the tools used — not `tool_result` contents or thinking signatures,
which are what inflate the file (4.59 MB of transcript → 0.09 MB).

The app no longer shows conversations. The archive stays because the
same reading of transcripts tells the browser extension which session
has just been driving a browser, and as a record you can read with
`GET /archive/<sid>`.

Everything already on disk is picked up by a separate script, with the
daemon stopped (it holds the archive index in memory):

```bash
launchctl bootout gui/$(id -u)/com.laserbeak.daemon
node scripts/archive-import.js          # --dry for a dry run
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.laserbeak.daemon.plist
```

## Session details and controls

Each session row has a ⋯ menu (and the same on right-click; a
double-click opens the details):

| Item | What it does |
|------|--------------|
| Details | time and setup, below |
| Name and notifications… | a custom name instead of `CLAUDE_LABEL`, and a banner switch for this session alone |
| Model | `/model opus`, `fable`, `sonnet`, `haiku` |
| Effort | `/effort low` … `max` |
| Compact context… | `/compact`, after a confirmation |
| Interrupt the turn | Ctrl-C, while it is working |
| Remove from list | for a session the daemon still thinks is alive |

Model, effort and compaction only appear for a Claude Code session
started with `start`. **Model and effort are global**: Claude Code saves
the choice as the default for new sessions — that is its behaviour, not
ours, and the menu says so.

The details show the total working time (the sum of all turns, which
accumulates until the session is closed for good), the number of turns,
the last turn, how long the session has been open, its agent, mode,
effort, folder, and whether it can be steered from outside.

A custom name and the notification switch are applied **on the daemon
side**, so they take effect everywhere: in the window, in the menu bar,
in the extension and in the banners. Stored in
`~/.laserbeak/sessions.json`.

### Project colour and icon

The brush on a project card opens a colour picker (8 options) and an
icon picker (16 from the Lucide set). A project becomes recognisable at a
glance:

```
🚀 storefront                             2 sessions     ← orange rocket
🗄 atlas-api                              3 sessions     ← teal database
```

The colour name is stored rather than its hex code: system colours adapt
to light and dark themes themselves, and the name stays readable in
`projects.json`.

The same colour and icon end up in the notification banner.

These settings live in the registry's `settings` field, so they are kept
for every project — even closed ones that are not in the list. An empty
value means "as default" and is not stored in the file.

### Lucide icons without a library

SwiftUI cannot do SVG. Rather than pulling in a dependency, the geometry
of sixteen icons is converted once into SwiftUI `Path` commands by
`scripts/make-lucide.py`, with the result in
`app/macOS/LucideIcons.swift`.

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

It asks nothing; the language is passed up front — `uk`, `en`, `cs`,
`ru`, `kk`, or `auto` for the system's:

```bash
LASERBEAK_LANG=cs npm run install:all
```

The script installs `tmux` and `terminal-notifier`, builds the `.app`,
puts it in `/Applications`, registers two LaunchAgents (autostart at
login), writes the hooks into `~/.claude/settings.json` — with a backup,
leaving other settings alone — adds `start`/`stop` to `~/.zshrc` and
installs the reply-cards mod. Reinstalling keeps the language you had.

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

Requirements: Node 18+, Xcode, `xcodegen` (`brew install xcodegen`), zsh
(the macOS default) for `start`/`stop`, and a signing certificate — see
the next section.

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

### What Claude Code can and cannot do for you

Most of the setup is scriptable, and Claude Code will handle it: install
`tmux` and `terminal-notifier` via Homebrew, build and sign the app with
your certificate, register both LaunchAgents, patch the hooks into
`~/.claude/settings.json`, wire up `start`/`stop`, install the mod and
verify the daemon answers.

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

**The window is opened from the menu bar** — "Open Laserbeak" (⌘O), a
click on any project or session listed there, or "Settings…" (⌘,)
straight into the settings. It comes to the front even when another app
is active. The close button just closes
it; the app keeps working. To quit for real, use "Quit" in the same menu.

The window has a sidebar:

| Section | What is there |
|---------|---------------|
| **Sessions** | open projects as cards, sessions in them marked Claude or Codex: status, turn time, memory, mode, the ⋯ menu; a speaker per project to silence its banners; how many need you, are working, have finished |
| **Activity** | what happened, by day: sessions opened, finished, asked for permission |
| **General** | language, version, where the data lives, the daemon log |
| **Notifications** | per event — finished, permission, input reminder, new version — on/off and a sound |
| **Updates** | is there a newer version on GitHub, what is new, how to install it |

When a new version is out, a green note appears at the bottom of the
sidebar, and the menu bar gets an "Update available" item.

The menu bar icon:

| Icon | What it means |
|------|---------------|
| `○ 3` | 3 sessions, all idle |
| `◐ 2` | something is working right now |
| `⏸ 1` | Claude is waiting for permission |
| `⚠︎` | the daemon is not responding |

### Language

One language for everything — the window, the menu bar, banners, the
event history, API errors, the browser extension, `start`/`stop` and the
first prompt they send. It is set at install time and changed in
Settings → General, with a flag next to each language. Banners switch at
once; the window follows after a relaunch, which it offers.

To look at the app in another language without changing anything:

```bash
/Applications/Laserbeak.app/Contents/MacOS/Laserbeak -AppleLanguages '(cs)'
```

### Updates

Every six hours Laserbeak asks GitHub whether the branch this copy was
cloned from has new commits, and says so with a banner. It only reads:
nothing is downloaded and the working copy is not touched.

Installing it is yours: Settings → Updates spells it out, with what is
new and the commands ready to copy —

```bash
cd /path/to/Laserbeak
git pull --ff-only
npm run install:all
```

— then reload the browser extension. Your language and settings stay;
the installer takes them from `config.json`. Or open the folder in
Claude Code and ask it to update Laserbeak: `CLAUDE.md` tells it how.
Nothing is rebuilt behind your back, and if `git pull` stops (your own
commits diverge from GitHub), you see it right there in the terminal.

Automatic checks are switched off in the same section.

### The notch island

On a MacBook with a notch, Laserbeak puts its own small island around it —
like the Dynamic Island on an iPhone. On the left of the notch, the marks
of the agents at work — Claude, Codex, Gemini — each once; on the right,
how many are waiting for permission (orange), or else how many are
working (blue). While someone waits, the whole island is outlined in
orange.

```
   ✳ ֍ ┌──────── notch ────────┐ 2        ← two agents need you
```

When a session asks for permission, the island does not wait for a
glance: it opens by itself and shows just the sessions that are waiting,
each with what it wants to do (*running: Restart the daemon*, *asking you
a question*). It stays open until you answer — the daemon sees the answer
in the transcript — and a click elsewhere does not hide it, since you
click all the time and would miss it; a click on the island itself does.
A new request opens it again. A list you opened yourself still folds on
a click anywhere else.

A click expands it downwards: who is waiting, who is working and what
exactly they are doing (*editing server.js*, *searching “notch”*), how
long the turn has been running and how much memory the session holds —
the agent together with everything it started. A Codex session driving
its own browser easily weighs 1.5 GB, while the agent itself is 200 MB;
the session details show the same, with the number of processes. A click on a row opens the editor the
session was started from, the line at the bottom opens the Laserbeak
window; a click anywhere else folds it back.

On a display without a notch — an external monitor — the same thing is a
slim strip in the middle of the menu bar: the agent, the session, what it
is doing and the turn's time.

```
              ✳ Kalyna 2  editing Island.swift  3:42  +2
```

Sizes come from the menu bar of each screen, so the island sits the same
on a MacBook Air, a Pro and in scaled modes. The right wing never covers
menu bar items: it is only as wide as the room left of the first of them.
When that is tight, the island first trims its own margin, and only when
even then the number does not fit does it move to the left of the notch. What a session is doing comes from its transcript;
shell commands are never shown, only the description Claude gives them,
since a command can carry a token. Settings → General chooses between the
island and just the circle with a number in the menu bar, which is always
there.

### If the app crashes

The daemon checks every ten seconds whether the app is reachable and
brings it back: about a minute from crash to recovery. What is checked is
not a row in the process table but whether the app is holding an open
notification request. "Quit" still works for real: a deliberate quit
leaves a marker, and while it is there the daemon leaves the app alone.

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
rules are already new. Most of it is changed from the app.

```jsonc
{
  "port": 8787,

  // uk | en | cs | ru | kk | auto — one language for everything
  "language": "auto",

  // The extension allowed to talk to the daemon. Empty means any
  // extension; pages from the network are refused either way.
  "extensionId": "bcibihhnnjblcbgehfemebkkdcnhjmnf",

  // Which events show a banner — Settings → Notifications
  "notify": { "stop": true, "permission": true, "idle": false, "update": true },

  // System sounds from /System/Library/Sounds. "" = silent.
  "sounds": { "stop": "Glass", "permission": "Funk", "idle": "Tink", "update": "Ping" },

  // Check GitHub for a newer version — Settings → Updates
  "updates": { "check": true },

  "historySize": 200
}
```

Older configs may still carry `bindHost`, `serviceName` and a
`~/.laserbeak/token` — leftovers of the phone app, ignored now.

### About security

The daemon listens on `127.0.0.1` and nowhere else — that is not a
setting. Everything that talks to it is on the same computer: the app,
the extension, the hooks, `start`.

Since a browser extension also talks to the daemon, trusting localhost
stopped being free: a `POST` from a page arrives without a preflight,
i.e. it executes, even though nobody sees the response. So the daemon
inspects `Origin` and refuses pages from the network.

The only thing Laserbeak sends out is the update check: one request to
`api.github.com` every six hours, switchable off.

---

## Session labels

`start` and `stop` live in `shell/laserbeak.zsh`, and the installer adds
one line to `~/.zshrc` that loads them:

```bash
source "/path/to/Laserbeak/shell/laserbeak.zsh"
```

If your `~/.zshrc` already has a `start()` of its own (an older copy),
the installer leaves it alone and prints the line to replace it with.
They take effect in new terminal tabs.

`start "backend"` → the label `backend` appears in the banner, in the
window and in the extension. Without a label, the terminal's tty name is
used.

```bash
stop            # what is running and how much memory it holds
stop backend    # kill that session
stop -a         # kill every detached one; open tabs are left alone
```

### Codex: `start codex "name"`

The same command starts **Codex** instead of Claude Code:

```bash
start codex "api"              # Codex in tmux, labelled api
start codex api "fix the build"
start -n codex api             # no documentation request
```

It is connected the same way: the session shows up in the window and in
the browser extension's picker (marked "Codex"), with statuses — working,
done, **permission needed** — banners, and screenshots from the browser. `codex` does not have to be on `PATH`:
`start` finds the one bundled inside ChatGPT.app.

**The first time**, Codex stops with "Hooks need review — 6 hooks are
new or changed". Those are Laserbeak's (all of them call `hook.sh`): pick
"Review hooks" or "Trust all and continue". This is Codex's own
safeguard, asked once; Laserbeak does not skip it. Until they are
trusted, Codex runs fine, it just stays invisible to Laserbeak.

What is Claude-only: the conversation archive (Codex keeps its history
in a different format), and switching the permission mode, the model or
the effort — Codex organises those differently, so the app does not
offer them for a Codex session.

### The first prompt reads the documentation

Asking a session to read `docs/` before it starts guessing is the kind of
thing that is easy to forget every single time. So `start` asks on your
behalf: it passes Claude a first prompt naming the documentation the
project actually has — in the language picked for Laserbeak.

Two files are deliberately left out. `CLAUDE.md` — Claude Code loads it
by itself, and asking again would only mean reading what is already in
context. (Codex does not: it loads `AGENTS.md`. So for `start codex`,
`CLAUDE.md` goes first on the list whenever there is no `AGENTS.md`.) And `README.md`, whenever `docs/` exists: there it retells the
documentation for the user, which is tens of thousands of tokens spent on
a duplicate. With no `docs/`, the README is the only documentation there
is, and it goes in.

The project root is found by walking up from the current directory
(`.git` or `CLAUDE.md`), because sessions are often opened in a subfolder
while the documentation lives at the top.

### The size of it

Measured on this project: `docs/` is 68 KB, which is about 24,600 tokens.
A session starts at roughly 37k (system prompt, tool definitions,
`CLAUDE.md`), so the request costs a fifth of a 200k window — and it buys
a session that does not have to re-derive how the daemon works. It is
paid once; from there the prompt cache carries it at a tenth of the
price.

But documentation folders vary wildly. In a neighbouring project `docs/`
is 27 files and 497 KB — around 175k tokens, which would swallow a 200k
window whole before the first request. So there is a budget: over 120 KB
(~40k tokens) the prompt stops enumerating files and asks the session to
look at `docs/` and pick what to start with instead. `CLAUDE.md` is
already in its context to guide that choice.

Nothing is added when there is nothing to add:

| | |
|---|---|
| `start api` | asks to read the documentation |
| `start api "fix the build"` | your own prompt wins, no request added |
| `start -n api` | no request this time |
| a project with no `README.md` and no `docs/` | starts as before |

The text arrives as a separate argument, so tmux passes it through
without running it past a shell — spaces and asterisks survive intact.

---

## Replies as cards

`claude/reply-cards` is a Claude Code mod. It teaches Claude a reply
layout — numbered cards: what changed, what was taken as decided,
**important to know**, **questions** — and draws them as rounded boxes
coloured by title: light blue for most, yellow for "important", purple
for questions, always last. A short reply stays plain text.

```
╭─────────────────────────────────╮
│ 1  What changed                 │
│    The mod draws replies as …   │
╰─────────────────────────────────╯
╭─────────────────────────────────╮   yellow
│ 2  Important to know            │
╰─────────────────────────────────╯
╭─────────────────────────────────╮   purple
│ 3  Questions                    │
╰─────────────────────────────────╯
```

The installer adds this repository as a plugin marketplace and installs
`reply-cards@laserbeak` for your user, so it is on in every new session.
The mod is read from the repository itself: an update brings it along,
`/reload-plugins` applies it to a running session. Card titles are
recognised in Ukrainian, Czech and English.

Someone without Laserbeak can install just the mod:

```
/plugin install reply-cards --marketplace TimeSkipe/Laserbeak
```

---

## Layout

```
src/              the Node daemon
  daemon.js         entry point
  server.js         HTTP API and its two entrance checks
  events.js         hook event handling
  state.js          sessions, history, per-project rollups
  projects.js       project registry (survives restarts)
  sessionSettings.js  custom session names and notification switches
  settings.js       what the window may change in config.json
  updates.js        newer version on GitHub, and how to install it
  archive.js        conversation archive (transcripts live only 30 days)
  shots.js          region screenshots from the browser → prompt into a session
  roots.js          resolving the project root from a working directory
  inspect.js        process inspection: terminal tabs and live claude processes
  notify.js         macOS notifications
  outbox.js         notification queue for the app (long-poll)
  appguard.js       keeps the Mac app alive
  i18n.js           text in five languages
  config.js         config, re-read on the fly

app/
  project.yml       Xcode project description (xcodegen); .xcodeproj not in git
  macOS/            the window, panes, menu bar, banners, models
  Resources/        app icon, String Catalog (five languages)

extension/        browser extension: drag a region → send it to a session
shell/            start / stop and their tmux.conf
claude/reply-cards/  the Claude Code mod: replies as cards
.claude-plugin/   makes the repository a plugin marketplace
hooks/hook.sh     the session → daemon bridge
scripts/          install, update, build, icons, settings.json patching, l10n check
```

---

## Commands

```bash
npm run logs        # tail the daemon log
npm run errors      # only what went wrong, daemon and app, with the reason
npm run state       # current state as JSON
npm run restart     # restart the daemon
npm run build:app   # rebuild the macOS app
npm run extension   # copy the extension folder path to the clipboard
npm run check:l10n  # every string in every language
npm run xcode       # open the project in Xcode
```

To regenerate the icons from a different image:

```bash
python3 scripts/make-icon.py path/to/image.png && npm run build:app
```

---

## HTTP API

Full description in [docs/api.md](docs/api.md). Everything is on
`127.0.0.1`; a page from the network is refused by its `Origin`.

| Method | Path | What |
|--------|------|------|
| POST | `/hook/<event>` | events from sessions |
| GET | `/state`, `/health` | everything the app shows |
| POST | `/refresh` | the same, after checking everything now |
| GET, POST | `/settings` | language, banners, sounds, update checks |
| GET | `/update` | the update status |
| POST | `/update/check` | check now |
| POST | `/sessions/mode`, `/command`, `/interrupt`, `/forget`, `/settings` | steering a session |
| POST | `/sessions/shot` | a screenshot from the browser |
| POST | `/sessions/input`, `/spawn`, `/stop` | the primitives; the app no longer uses them |
| POST | `/projects/settings`, `/projects/forget` | colour and icon |
| GET | `/archive`, `/archive/<sid>` | the archive |
| GET | `/events/wait` | banners for the app (long-poll) |

Events: `session-start`, `prompt`, `stop`, `notification`, `session-end`
(Codex adds `approval`, `interrupt`).

---

## What's next

- **Open a project in its editor** — the bundle id is already remembered.
- **Quiet rules** — do not notify when you are looking at that very
  project.
- **Capturing a longer page** — only the visible area is taken today;
  scrolling and stitching would give the whole list rather than the first
  screen.
- **The archive for Codex** — its rollout files are a different format.
