# What we learned the hard way

Collected here is everything that turned out not to be what it looked
like. Every entry once cost hours. Before "simplifying" something in the
code, look for it here first — chances are the simple version has already
been tried.

---

## Terminals and input

### You cannot type into someone else's terminal

The `stdin` of a live `claude` process is a pseudo-terminal
(`/dev/ttysNNN`) whose master is held by WebStorm. Injecting characters
from outside used to be possible with the `TIOCSTI` ioctl, but **macOS
removed it** — the constant is not even in the system headers any more.

So you can only write into a terminal you created yourself. Hence the
go-between: `start` runs claude inside tmux, and a pane can be written to
with `send-keys`.

### `/usr/bin/script` is no good as a pseudo-terminal

It calls `tcgetattr` on its own `stdin` and fails with
`Operation not supported on socket` when that is a pipe rather than a
terminal. Hence our own bridge, `src/pty-bridge.py`, built on `pty.fork()`.

### `tmux send-keys` interprets text as key names

Without the `-l` flag the word "Enter" inside a prompt would become an
Enter keypress. So the text is sent with `-l`, and Enter as a separate
call.

### `zsh -lc` does not read `.zshrc`

launchd has its own stripped-down `PATH`, so a bare `claude` is not
found. But with `-c` alone the shell does not read `.zshrc`, where nvm
and `~/.local/bin` are set up. What you need is `-lic` (login +
interactive).

### Text and Enter in one write leaves the prompt sitting in the input box

Found by end-to-end testing of browser screenshots, but the defect was
old and affected **any** input into daemon-started sessions.

`terminals.write` wrote `text + '\r'` into the pseudo-terminal in a single
call. Short prompts got away with it, but a long one is recognised by
Claude Code as a **paste** — and the `\r` in that same write becomes part
of the pasted text rather than a submission. The prompt sat quietly in
the input box until the next one pushed it out; then both flew off stuck
together:

```
…Region 420×180.say ok
```

The em dash `—` also disappeared from the middle of the line — not
through an encoding problem, but through that same paste handling.

The tmux path never has this, and that was the clue: `send-keys -l <text>`
and `send-keys Enter` are two separate process invocations, i.e. two
separate writes with a natural pause between them. Now the same applies
to our own sessions: text, a 50 ms pause, `\r`.

The moral: when the same input travels two paths and one of them
misbehaves, compare them down to the last call, not down to the last
function.

---

## Notifications on the Mac

### An ad-hoc signature blocks notifications

With a `-` signature macOS denies the app notifications
(`Notifications are not allowed for this application`) and does not even
show a permission prompt. A real Apple Development certificate is
required.

### The refusal is cached against the bundle id forever

A correct signature is not enough: the system remembers the earlier
refusal. We had to change `PRODUCT_BUNDLE_IDENTIFIER` to a new one
(`com.laserbeak.desktop`) to get a fresh record.

### The app must be launched via `open`

If a LaunchAgent runs the binary inside the `.app` directly,
LaunchServices does not register it — and notifications may stop working.
Hence `/usr/bin/open -g -a <path> --args --background`.

### An app launched by LaunchServices has no stdout

No terminal, no launchd log. So `AppLog` writes to its own file,
`~/.laserbeak/app.log`.

### The first notification after a daemon restart went missing

The event counter starts at zero, while the app remembered a higher
number and filtered the event out itself. Now **only the daemon** filters
— the client shows everything it receives.

---

## The browser extension

### An image can be handed to a session as text

Input into a session is `tmux send-keys`, i.e. characters. You cannot put
a screenshot there, and it seemed a separate channel would be needed for
images.

It is not: Claude Code reads images from disk with its own `Read`. So the
daemon puts the shot in `~/.laserbeak/shots/` and sends the session an
ordinary string with the path. `input.js` knows nothing about screenshots
and does not need to.

### Newlines in a prompt mean submit

The prompt assembled from a screenshot looked handsome across several
lines: path, comment, page address. It arrived at the session **in
pieces** — every `\n` is an Enter, i.e. a separate prompt. The session saw
a fragment and started answering it.

So the text assembled in `shots.js` is a single line, and the user's
comment goes through `flat()`: it, too, can span paragraphs.

### A selector with no anchor at the top matches half the page

The value of the whole exercise is only half the picture; the other half
is the selector of the element under the region: the picture says what is
wrong, the selector says where it lives in the code.

The first version walked up the tree until the path became unique, and
looked right. On GitHub it produced
`#_R_nd_ > ul > li > div > ul > li > a`, and that path matched **58**
links. The reason: the walk stopped after six levels without reaching an
anchor, and `ul > li > a` with no root binding means "anywhere on the
page" — no amount of `:nth-of-type` narrows that down.

Fixed by anchoring at `body` and checking
`querySelectorAll().length === 1` at every step. Verified on 140 elements
across two very different sites (GitHub and react.dev — semantic classes
and Tailwind): all 140 exact, median length 46–67 characters.

The moral is broader than this case: a selector that matches sixteen
elements is worse than an honest short one — the session will follow it
to the wrong place and silently fix the wrong thing.

### Hashed classes cannot be found in the code

`styled-components` and CSS modules produce classes like `sc-a1b2c3d` and
`css-1x2y3z`. In a selector they look convincing, but you will never grep
them — they are generated. So such classes are discarded: better a bare
tag plus a path than a false trail.

### Inside a `<canvas>` there is nothing to point at

Verified on a live map: the region produced the selector
`canvas.maplibregl-canvas` — formally correct and almost useless at the
same time. The entire MapLibre map is one canvas with no DOM elements
inside, so a more precise address does not exist in principle.

This is not our defect and nothing can fix it. It is simply a limit worth
knowing: for a normal interface the selector gives an address in the
code, while for a map, a chart or a video what remains is the picture
itself — and the page address, which for maps usually carries the
coordinates (`#12.64/50.0875/14.4213`).

### The element's text turned out to matter more than expected

The `text` field was added as a minor hint about "what it says there". On
a real listing page it brought a whole row of data into the prompt —
price, area, address — meaning the session received part of the picture
as **exact text** rather than "as far as it could make out". For
interfaces full of numbers that is noticeably more reliable than reading
them off a JPEG.

### A visible-area capture is not the whole page

`captureVisibleTab` captures exactly what is on screen. On a list of 57
cards, four made it into the frame, and the session's answer was about
those four. There is no bug here, but when reading an answer about "all"
the elements, remember how many were actually visible.

### Our own `CSS` constant shadowed the global `CSS.escape`

The overlay's styles lived in ``const CSS = `...` ``, and right next to it
was `CSS.escape(node.id)` — not a build error but a half-past-runtime
one: a local constant shadows the browser's global object. It was caught
only by reading the code. The constant is now `STYLES`.

### The frame arrives in physical pixels, the region is drawn in CSS pixels

`captureVisibleTab` returns the whole visible frame in screen pixels,
while the region's coordinates come from the page in CSS pixels. On
Retina that is exactly a factor of two.

Verified with a fake frame carrying a marker at a known position: with
the `devicePixelRatio` multiplication the crop contained 10,000 marker
pixels and **not one** background pixel; without it, not a single marker
pixel at all. So the error is not "slightly off" but "cropped something
else entirely".

The capture is taken after the overlay has hidden itself, with a pause
for repainting — otherwise our own frame lands in the shot.

### The card was measured before its picture existed

A region near the bottom of the screen left the comment card hanging off
the edge — the text field below the fold, impossible to click. The code
did clamp the card to the screen, using its measured height. But the
preview is a data-URL `<img>`, and even a data URL decodes
asynchronously: at the moment of measuring, the picture had no height
yet. The card was placed as if it were 67 px shorter, then grew
downwards. Measured on a real case: 58 px off screen.

Now the card is re-placed whenever it changes size (`ResizeObserver`) or
the window does: below the region if it fits, above it if not, and
pressed against the bottom edge as a last resort. On a very short screen
the preview shrinks first — the card is pointless without the text field,
not without a big picture.

### The overlay has to live in a Shadow DOM

The frame is drawn on top of someone else's page, and out there you meet
both a global `* { box-sizing: border-box }` and a
`div { position: static !important }`. A Shadow DOM with `all: initial`
severs that link in both directions: the page cannot reach us, and we
leave nothing behind in its CSS.

### A Shadow DOM hides styles, not events

Open a modal, then the extension, start dragging a region — and the modal
is gone. A Radix dialog closes on any `pointerdown` outside itself,
listening on `document`. An event from inside our shadow tree reaches
`document` retargeted to the host, i.e. to an element outside the dialog,
so the dialog closed on the first press of the frame, before the shot was
even taken.

Two more of the same kind, read in Radix's code and then confirmed on a
test page with the real library:

- **Escape.** Radix catches it on `document` in the capture phase, ahead
  of our own listener there — Esc cancelled the frame and closed the modal
  with it. Our listener now sits on `window`, the first stop on the path.
- **Focus.** Moving focus from the modal's input to our comment field
  fires `focusout` on the page's input, with our host as `relatedTarget`.
  Radix's focus trap pulled focus straight back, and the comment was typed
  into the modal instead of the card.

So the page hears nothing from the overlay. Pointer, mouse and key events
stop at the shadow root once our own handlers have run; focus events that
tell the page "focus went to the overlay" are stopped on `window`. Default
actions — focusing, typing, opening a `select` — do not depend on
propagation and keep working. When the overlay closes, focus goes back to
where it was; the page never learnt it had left.

Headless UI needed none of this: its dialogs treat every direct child of
`<html>` and `<body>` as a "third-party root" and ignore clicks there, and
our host is exactly that.

Still out of reach: listeners a page put on `window` in the capture phase
before the overlay arrived, and a native `<dialog>` opened with
`showModal()`. That one lives in the top layer, above any `z-index`, and
the frame ends up under its backdrop — the dialog stays, but no region can
be dragged.

### The browser sorts session tabs out for us

It seemed the "tab → session" link would have to be guessed from
`windowId` or from a localhost address. In fact Claude in Chrome puts the
tabs of one conversation into their own **tab group**, and `tabGroupId` is
visible through `chrome.tabGroups`. That is a fact from an API, not a
guess.

Also worth knowing: the Claude in Chrome extension does not necessarily
live in Chrome. You can find the browser your sessions drive by its
native host —
`NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json`
in the profile directory. On this machine it is Brave; our extension has
to be installed there too, otherwise it would be looking at entirely
different tabs.

### The service worker needed no waking

MV3 puts a service worker to sleep after ~30 seconds without events, and
it is usually kept alive artificially — a `chrome.alarms` tick every 20
seconds. That was not needed here: messages flow between drawing the
region and pressing Enter, and those keep the worker alive. The capture
still lives in `chrome.storage.session` rather than in a variable — so it
survives sleep if the user stops to think.

### An automated drag does not carry Shift into the moves

The markup editor straightens a shape while Shift is held, reading
`shiftKey` from `pointermove`. Driven through browser automation — a drag
with the `shift` modifier — it drew an ellipse, not a circle, and the
Shift code looked broken.

It was not. The same drag dispatched by hand as `PointerEvent`s with
`shiftKey: true` drew a perfect circle, so the modifier from the tool
simply never reached the move events. When testing anything keyed on a
modifier held mid-drag, dispatch the events yourself before suspecting
the code.

The same rig has a second habit: right after a navigation, drags went
nowhere — the veil was up, its hint untouched, not a single `mousedown`
arrived — until a screenshot of the tab had been taken. After that every
drag landed. Three times in a row it looked like a broken overlay; it was
the rig.

The reason is probably the same as for a third habit: that tab reports
`document.visibilityState === 'hidden'` and draws no frames on its own.
Whatever is delivered on a frame — `requestAnimationFrame`,
`ResizeObserver` — waits until the next screenshot forces one. The card
placement looked wrong by exactly the height of a late image until a
screenshot was taken; then it was right. Measure after a screenshot.

### `activeTab` instead of `<all_urls>`

The temptation to ask for access to every page is strong — then it works
everywhere, immediately. But clicking the icon, the keyboard shortcut and
the context menu all grant `activeTab` by **themselves**: permission for
the tab you just acted in, and only for now. The extension never sees the
rest of your pages.

## The Mac app watchdog

### launchd's KeepAlive does not go with launching via `open`

The app is the menu bar and the banners with project icons, so it should
always be alive. `KeepAlive: true` looks sufficient — it is not.

It has to be launched via `open`, otherwise LaunchServices does not
register it and notifications break. And `open` exits immediately, handing
the work to LaunchServices, so launchd would treat that as a crash and
relaunch `open` every ten seconds, forever.

So the daemon does the watching: it is always alive anyway and knows
exactly whether the app is reachable. The sign of life is not a row in
the process table (a process can hang around doing nothing) but whether
the app is holding an open request on `/events/wait`.

### A sleeping Mac looked like a crashed app

`setInterval` does not tick while the Mac sleeps. So after waking, the
next tick arrived with a half-hour hole in it — and the watchdog read
that as "the app was silent for half an hour". Over a day that added up
to a couple of dozen "silent — bringing it back" entries out of nowhere;
harmless (`open` on a running app does nothing) but they cluttered the
log, and a real crash would be lost among them.

Telling them apart is simple: a gap between ticks larger than several
ticks is not silence, it is us having been away. After such a gap the app
gets a minute to raise its `/events/wait` request.

### Detection delays add up, they do not overlap

The notification queue considers a client alive for another 45 seconds
after its last request. I put another 90 seconds of "silence" on top,
thinking of it as slack — in fact they add up, and the app came back only
after two and a half minutes.

The extra margin should be small: the queue has already waited on our
behalf. With 15 seconds the app comes back in 55.

### "Quit" has to actually quit

If the daemon brings the app back, the "Quit" menu item looks broken: you
closed it, and a minute later it is back.

So a deliberate quit leaves `~/.laserbeak/app-quit` behind. While that
file exists, the daemon leaves the app alone; the app itself removes it on
next launch — including at login.

## Claude Code's data

### Transcripts live for about 30 days

Verified: 518 MB, 758 files, the oldest exactly 31 days old. So
conversations disappear on their own. Hence the archive.

### `permission-mode` in a transcript is not the current mode

These records are written **on every user prompt**, not on every mode
change. So it is the mode as of the last message. I read exactly those at
first, and switching worked while the check could not see it.

The live source is the indicator in the bottom status line
(`⏵⏵ auto mode on`), read via `capture-pane`.

### The Shift+Tab cycle order is not documented anywhere

So the daemon does not assume it: it presses and re-reads the indicator
each time until it gets the mode it wants. The real values: `auto → plan`
three presses, `plan → default` two.

### The `Notification` hook fires for two different things

```
"Claude needs your permission…"      a real permission request
"Claude Code needs your approval…"   plan approval
"Claude is waiting for your input"   just waiting for you to type
```

The last one arrives about a minute after an ordinary reply finishes. If
you do not tell them apart, the session looks as if it were asking
something.

Telling them apart by text was fragile: the text is English and lives in
Claude Code's own string table, so a rewording or a translation would
have quietly turned every permission request into "waiting for input" —
whose banner is off by default. The hook payload carries
`notification_type`, a required field (checked in the 2.1.306 binary:
`permission_prompt`, `worker_permission_prompt`, `idle_prompt`,
`auth_success`, `agent_needs_input` and a few more). `events.js` trusts
the type first; only an unknown or missing type falls back to the text,
which still catches plan approval — that one goes through a dialog
without a type of its own.

### A project name cannot be recovered from the transcript directory name

Claude Code encodes the path by replacing `/` with `-`, and project names
contain hyphens themselves: `atlas-api-v3` turned back into `v3` when
parsed in reverse. You have to take `cwd` from the transcript itself.

---

## Claude Code commands

### "● high · /effort" is a hint for newcomers, not an indicator

A tempting find: a fresh session draws the effort level in the bottom
status line, in exactly the same place as the permission mode. So that is
what I did — read it together with the mode in one `capture-pane`.

On live sessions it turned out to be empty. The reason: that line is
shown only to a new session and disappears as soon as any work happens in
it. In a pane where work is already under way, only the mode remains.

The reliable source is `~/.claude/settings.json`, key `effortLevel`. That
is where Claude Code writes the choice — the command says as much:
"saved as your default for new sessions".

### Model and effort are global, not per-session

`/model sonnet` and `/effort low` change the current session **and** are
saved as the default for new ones. In the model picker this is stated
outright:

```
Enter to set as default · s to use this session only · Esc to cancel
```

So a per-session change is only possible through the interactive picker
with an `s` keypress. Driving that picker blind is fragile: the order of
entries is not fixed. So we send `/model <name>` and honestly label it in
the app as the default value.

A side effect I got burned by while testing: these commands rewrite the
user's `~/.claude/settings.json`. When trying them out, remember the
original values and put them back.

## Processes

### In a WebStorm terminal `TERM_PROGRAM` is empty

The reliable source is `__CFBundleIdentifier`, which macOS sets itself:
the bundle id of the app the terminal was launched from
(`com.jetbrains.WebStorm`). This is why clicking a notification took so
long to start opening the right window.

### A terminal tab is a shell whose **immediate** parent is the editor

```
webstorm
├── zsh            ← a tab
│   └── claude
│       └── zsh    ← the Bash tool inside the session, NOT a tab
```

Without the immediate-parent condition, the utility shells Claude Code
spawns itself end up in the count.

### A process does not reveal its session

Verified: there is no session id in the process environment, and `claude`
does not hold the transcript open (you will not find it via `lsof`). The
only exact route is `hook.sh` passing `$PPID` and the daemon walking up
the tree to `claude`. For tmux sessions the pid comes straight from the
pane.

### `pgrep -x claude` is unreliable

Out of eight processes it missed one. Inspecting via
`ps -eo pid=,ppid=,comm=` and comparing `basename` gives the right
answer. If you need a process count anywhere, this is the only way.

### A process in a subdirectory must belong to exactly one project

Otherwise a tab in `storefront/functions` was counted twice: once for
`functions` and once for `storefront`. The **deepest** directory
containing the path wins.

### A session in a subfolder must not create a new project

`my-app` and `functions` inside one repository became separate rows in
the list. The root is found like this: the project open in the IDE → the
nearest ancestor with `.git` or `.idea` → the directory itself.

### `tmux kill-server` in a test kills the real work

On 31 August 2026 a session in this project tested the `start` and `stop`
functions from `~/.zshrc` and ended both of its test scripts with
`tmux kill-server`. Every session started through `start` lives in the
same tmux server, so both times all three working sessions died at once.
The tabs came back to a clean prompt with no `lost server` to hint at
what had happened — a graceful `kill-server` destroys sessions properly,
and only an unexpected death of the server prints that line.

`TMUX_TMPDIR` does not isolate such a test. The socket path built from
the scratchpad came to 143 bytes and `sun_path` on macOS holds 104, so
tmux silently fell back to the default socket — the real server. The
test's own output gave it away: the live sessions were listed right next
to the invented ones, and the closing line read "the real server is
untouched: no server running".

Test on a named socket instead: `tmux -L proba new-session ...`. `-L`
takes a socket **name** inside the default directory, so the length limit
never comes into play.

`hooks/guard-tmux.sh` now refuses any `kill-server` that carries neither
`-L` nor `-S`. It is wired in as a `PreToolUse` hook on `Bash` in
`.claude/settings.json`, and it inspects the whole request — the command
that killed everything only contained the words inside a here-doc it was
writing to a file.

### JetBrains leaves `opened="true"` behind after quitting

The flag in `recentProjects.xml` is not cleared when the IDE is closed.
So it is only honoured for IDEs whose process is currently alive —
otherwise a project from an IntelliJ closed a week ago would hang around
in the list.

---

## Codex

### Codex has Claude Code's hooks — and asks before running them

Codex CLI (0.155, bundled inside `ChatGPT.app` rather than on `PATH`)
has hooks with the same events and the same JSON format as Claude Code —
checked against the `hooks.json` of its own bundled plugins. So Codex
needed no second bridge: `~/.codex/hooks.json` points at the same
`hook.sh` with `codex` as a second argument.

The difference is trust. Codex does not run new or changed hooks until a
person approves them: its first screen says "Hooks need review — 6 hooks
are new or changed" (verified: that screen is how we learned it had
found our file). There is a flag that skips the review for one run,
`--dangerously-bypass-hook-trust`, and we do not use it — not in
`start codex`, not in tests. Approving is the user's call, made once, in
Codex itself.

Testing without that flag means no hook runs, so what was verified is
the rest: the file is found, the daemon handles the six events (replayed
through `hook.sh` from a process named `codex`), and `start codex` builds
the right command.

### Codex runs its hooks from the process in the pane

That matters because the label and the tmux pane reach the daemon only
through the environment the hook inherits. Codex also has a shared
app-server mode, and hooks run from there would carry none of it. In the
terminal it is not so: every MCP server of a Codex session is a direct
child of the `codex` process in the pane, so the agent — and its hooks —
run right there. `$CLAUDE_LABEL` and `$TMUX_PANE` arrive as with Claude.

### A process named `codex` is not necessarily a session

The ChatGPT app keeps a dozen processes of its own named `codex`. So
Codex is not counted the way `claude` is in `inspect.js` — "live
processes in this project" would count the app. `procs.js` treats `codex`
as an agent only for the exact link "this hook → its session's pid", and
the reaper never judges a Codex session by counting processes.

### Codex does not read CLAUDE.md

It loads `AGENTS.md`. In a project with only `CLAUDE.md`, a Codex session
knows none of the rules — so the documentation prompt `start codex` sends
lists `CLAUDE.md` first, while `start` for Claude still leaves it out.

### Trying Codex leaves marks in its config

Launching the TUI once wrote `[tui.model_availability_nux]` into
`~/.codex/config.toml` (the "this is GPT-6" tip was shown), and a new
folder asks "Trust this folder?" and saves the answer — a `-c` override
does not skip that. When testing, run it from a folder that is already
trusted, keep a copy of `config.toml`, and put back exactly what the test
added. The desktop app writes the same file, so restore precisely, not
wholesale.

### A copy of a system binary is killed on sight

To replay hooks "from a process named codex", copying `/bin/bash` to
`codex` looked enough; macOS killed the copy with `137` before it ran a
line. A four-line C program that forks the hook works.

---

## Daemon state

### Restarting the daemon wiped every session

The daemon only learns about a session from a hook, so restarting it
mid-work meant forgetting everything that was open — and the next event
can be a long time coming, because the session is simply waiting for you.
Hence `sessions-live.json`.

The same goes for the archive: it also re-reads every transcript in the
index modified in the last 10 minutes.

### `launchctl bootout` is asynchronous

A `bootstrap` immediately afterwards fails with `Input/output error`. You
have to wait until the service is really gone.

---

## Swift and building

### Swift does not substitute defaults

The synthesised decoder throws `keyNotFound`, and decoding of the
**entire** response fails, not just one field. One new field in the daemon
would black out the interface until the app was rebuilt. That is why every
model has its own `init(from:)`.

### The session that owns a tab is written in its own transcript

Binding a tab group to a session started as "remember what the user
picked". That is fine once, but Claude in Chrome opens a **new** group per
conversation, so with several sessions running you re-pick constantly —
and picking wrong sends a screenshot into somebody else's work.

The signal was already on disk. The daemon reads transcripts anyway, and
every browser action leaves a `tool_use` record named
`mcp__claude-in-chrome__*`. So "who has just been driving a browser" is a
fact, not a heuristic — it goes into `/state` as `lastBrowserUse`, and the
extension binds a fresh tab group without asking.

Two details that matter in practice. The daemon re-reads transcripts
every two seconds, so the trail can be a moment late — `onCreated`
therefore tries again after three seconds instead of giving up. And the
tool-name check is deliberately wide (`playwright`, `puppeteer`, plain
`browser`): the tab-to-session link does not depend on which MCP server
drives the browser.

### `%@` with an Int crashes, and it compiles cleanly first

Converting interpolated strings to `String(format:)` for translation, I
turned `"\(shown)\(of) повідомлень"` into `"%@%@ повідомлень"` — where
`shown` is an `Int`. It builds without a warning, because `Int` conforms
to `CVarArg`; then `%@` tries to treat the number as an object pointer
and the app dies with `EXC_BAD_ACCESS` inside
`__CFSTRING_IS_CALLING_OUT_TO_AN_OBJECT_FORMAT_ARGUMENT_WITH_CONTEXT__`.

The crash lands on whatever view uses the string — here, opening the
conversation — so it looks like a bug in that screen rather than in a
format specifier.

Two rules came out of it: `%d` for numbers and `%@` only for objects, and
positional arguments (`%1$d%2$@`) in anything with more than one
placeholder — translations reorder words, and the types must stay bound
to their own slots.

When touching format strings, audit every call at once: of thirteen sites
converted, twelve had matching types and one did not, and only that one
was reachable from a button.

### A missing i18n key is worse than an untranslated string

`chrome.i18n.getMessage()` returns an **empty string** for a key that is
not in `messages.json` — no warning, no fallback to the key name. So a
typo does not leave you with Ukrainian text in an English UI; it leaves
you with a blank button.

That is why the key sets are compared against the code as a check: every
key used in `.js`, in `data-i18n` attributes and in the manifest must
exist in every locale (`npm run check:l10n`). Cheap to run, and it
catches the one failure mode that is invisible by eye.

### chrome.i18n cannot be switched

There is no API to make `chrome.i18n.getMessage()` answer in a language
other than the browser's. So following Laserbeak's language means reading
`_locales/<lang>/messages.json` ourselves (`i18n.js`) and doing the
`$NAME$` → `$1` substitution the way chrome.i18n does it. The strings
stay in the same files; only the lookup moved.

The extension used to have a language picker of its own. It went away
when the language became one for all of Laserbeak: two switches for the
same thing only meant the browser could disagree with the banners.

Two consequences. The overlay lives in a page and gets the table from the
service worker by message, so `_locales` is not made web-accessible. And
the manifest's own strings — the extension's name, the shortcut's
description — are resolved by the browser and stay in its language no
matter what is picked.

### HTML cannot reach chrome.i18n by itself

The popup's markup holds only keys (`data-i18n="howToSelect"`), and one
loop in `popup.js` fills them in. There is no declarative way: unlike
SwiftUI, where `Text("…")` localises for free, a static HTML page has no
access to the extension API until a script runs.

### One language, four places that translate

The interface strings live in the app, but the banner text is assembled
by Laserbeak — and in the `terminal-notifier` fallback there is no app in
the picture at all. Translating banners on the client would lose them
exactly when the app is closed.

So each part translates its own text — the daemon (`src/i18n.js`), the
app (String Catalog), the extension (`_locales`), `start`/`stop` (a table
in `shell/laserbeak.zsh`) — but the **choice** of language is one, in
`config.json`, and everybody asks the daemon for it. It used to be split
("banners from the config, the app from the device"), and a Czech install
then greeted you with a window in whatever the system was set to.

Logs are deliberately left untranslated. They are read by whoever opened
`daemon.log`, and grepping for "session not found" in five languages
would be worse than in one.

### SwiftUI localises literals for free, but only inside its own views

`Text("Проєкти")` takes a `LocalizedStringKey`, so adding the catalog was
enough — 85 strings started working with no code change at all. But
`return "простій"` in a model is a plain `String`, and so is
`Text(flag ? "on" : "off")`: those needed wrapping in
`String(localized:)` by hand. Out of 189 interface strings, 120 needed
the wrapper.

The build extracts the first kind into the catalog by itself; the
`String(localized:)` kind it does not, in this project at least — such a
string silently stays Ukrainian in every language. Hence
`scripts/check-l10n.py`, which reads the code rather than trusting the
catalog.

Strings with interpolation are a third case: `"\(count) сесій"` cannot be
a key at all. Those were rewritten as `String(format:)` with real
placeholders (`"%d сесій"`), which is also what makes word order
translatable — in some languages the number does not come first.

### A hardcoded Team ID means only the author can build the project

`app/project.yml` carried `DEVELOPMENT_TEAM: ABCDE12345` — perfectly
sensible while there was one machine and one author. On anyone else's Mac
the build fails: their certificate belongs to a different team, and the
one written down is not theirs to sign with.

Now the Team ID is resolved at build time from what is actually in the
keychain (`scripts/team-id.sh`). It lives in the certificate's `OU`
field, not in `CN` — the number in the CN parentheses is the
certificate's own identifier, and mistaking one for the other is easy:

```
CN = Apple Development: someone@example.com (FGHIJ67890)   ← not this one
OU = ABCDE12345                                            ← this one
```

The value reaches the build as `LASERBEAK_TEAM`, and `project.yml`
references it as `$(LASERBEAK_TEAM)`. So the repository no longer
contains anybody's identity, and the same clone builds for anyone with a
free Apple ID.

### One Ukrainian word, two English ones

"Оновити" was both the Refresh button over the session list and the
Update button in Updates. In a catalog keyed by the Ukrainian text that
is one key — so English got one of "Refresh"/"Update" for both, and Czech
"Obnovit" for installing a new version. A key is a meaning, not a
spelling: the refresh button is "Оновити список" now.

### ImageRenderer does not draw the contents of a ScrollView

Rendering a view to a png to check its look showed empty tiles where a
code block and a table should have been. There was no layout bug:
`ImageRenderer` simply does not draw what is inside a `ScrollView`. When
a test rig shows emptiness, first ask whether the rig can see anything
at all. To look at the real window, `screencapture -l <window id>`.

### Node reads HTTP headers as latin-1

A Cyrillic label (`start "проба"`) arrived as mojibake. You need
`Buffer.from(value, 'latin1').toString('utf8')`.

## Settings, language and updates

### `LASERBEAK_LANG` in the LaunchAgent beat the settings switch

The installer put the chosen language both into `config.json` and into
the daemon's LaunchAgent as `LASERBEAK_LANG`. The variable wins over the
config by design — it is for trying a language with one run. In the
LaunchAgent that meant the language could never be changed again short
of reinstalling: the switch in the window wrote the config, and the
daemon kept speaking the old language. The variable is gone from the
LaunchAgent; it is for manual runs only.

### Every reinstall reset the language to "auto"

`install.sh` took `LASERBEAK_LANG` or, without it, `auto` — and wrote
that into the config. Fine for the first install, wrong for every one
after: an update from the app runs the same script, and a Czech setup
quietly became "whatever the system says". Without the variable the
installer now keeps the language already in the config.

### "auto" is the interface language, not the region

The daemon used to read `AppleLocale` (`uk_CZ`, `en_US`): that is the
region format, not the language. A Mac with an English interface and
Czech dates is English. Now "auto" is the first of `AppleLanguages` that
Laserbeak knows — the same rule macOS uses to pick a language for the
window, so "auto" lands on one language everywhere. When none is known,
the daemon says English and the app sets English for itself too;
otherwise it would fall back to its development language, Ukrainian.

### The window's language is decided before our code runs

macOS picks the localization from `AppleLanguages` in the app's defaults
when the process starts. So the language goes there — by `install.sh`
before the first launch, by the app itself at every launch (from the
config), and by the settings switch — and a change needs a relaunch,
which the window offers. Checked with `-AppleLanguages (cs)` on the
command line: the whole window, menu bar included, follows.

### The update check reads GitHub, it does not fetch

`git fetch` would answer the same question but rewrites
`origin/<branch>` in a working copy someone may be using at that very
moment. One read-only request — the last 50 commits of the branch — and
looking for our `HEAD` in it gives "behind N" directly; when `HEAD` is a
local commit GitHub does not have, the first ancestor in the list gives
"ahead" or "diverged". Verified on a scratch clone in all three states.
Unauthenticated GitHub allows 60 requests an hour, so the check runs
every six hours and its result is kept on disk: the daemon restarts after
every edit in `src/`.

### Updating is a set of instructions, not a button

For a while the Update button ran `git pull` and `install.sh` itself, in
a script detached from the daemon (it has to be: `install.sh` restarts
the daemon, and a child spawned with `detached: true` — its own process
group — was verified to survive `launchctl bootout` of its parent). It
worked, but a rebuild of the app behind your back, with its outcome
reported afterwards from a log, was not what was wanted. The window now
shows what is new and the three commands to run, with a Copy button;
`CLAUDE.md` tells a Claude Code session how to do the same when asked.
A failed `git pull` is then visible where it happens, in the terminal.

### An agent app does not come to the front by itself

Opened from the menu bar or a banner, the window appeared — behind the
editor, in an app that was not active. Since macOS 14 activation is
cooperative and `activate(ignoringOtherApps:)` ignores its flag; an
`LSUIElement` app has no Dock icon to be clicked into focus either. To a
person that reads as "the app cannot be opened from the background", and
clicks into the half-hidden window only woke it up instead of switching
sections. So `AppRouter.show` asks for activation and also orders the
window front explicitly, a tick after SwiftUI created it:
`makeKeyAndOrderFront` and `orderFrontRegardless`, which works even when
activation is declined.

Testing this by synthetic clicks at screen coordinates is a trap: the
click lands on whatever window is on top there — another app, if the
Laserbeak window is behind it. Section switching was checked through
accessibility (`AXSelected` on the sidebar rows) instead, which needs
neither the mouse nor focus.

### A greyed-out menu item looks broken

The menu bar listed projects and sessions as `Text`, and in a menu that
is a disabled item: grey, and nothing happens on click. They are buttons
now, opening the window on Sessions.

## Quick commands and the reply mod

### `start` lived in one person's `~/.zshrc`

Everything that types into a session — screenshots from the browser,
mode and model from the app — needs the session to run inside tmux, and
`start` is what puts it there. But `start` and `stop` were written
straight into the author's `~/.zshrc`, so an install on any other machine
(by a person or by a Claude Code session following CLAUDE.md) ended up
without them, and nothing said so. They live in `shell/laserbeak.zsh`
now, and `install.sh` adds one `source` line. An existing `start()` in
`~/.zshrc` is left alone and reported: it is the person's file.

### A mod written in a session loads only in that session

The reply-cards mod was written into `~/.claude/dev-mods/<session id>/`,
the folder Claude Code hot-loads for the session that wrote it. Every
other session ran without it, and the cards seemed to come and go. A
plugin that loads everywhere has to be installed, and the cheapest
source is a folder marketplace: the repository carries
`.claude-plugin/marketplace.json`, and a plugin from a folder marketplace
is read in place, so `git pull` updates it without a reinstall.

## Icons

### SwiftUI cannot do SVG

Instead of a library, the geometry of the Lucide icons is converted once
into SwiftUI `Path` commands by `make-lucide.py`. Elliptical arcs (`A`)
are converted to cubic Béziers — SwiftUI has no arc with the same
parameters.

### The app icon looked too small

In the source image the mark occupied only 45% of the canvas, and our own
padding was added on top of that. Now the script finds the graphic's
bounds itself and trims the empty space: the tile is 82% of the canvas,
the mark 62% of the tile.
