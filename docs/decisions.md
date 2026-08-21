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

## Connecting to the phone

### Plain Bluetooth is no good for this

It feels natural: a Mac and an iPhone find each other instantly anyway.
But CoreBluetooth is GATT with ~180-byte packets and a real-world speed of
a few KB/s. A state snapshot is 12 KB and is fetched every two seconds; a
single session's archive is 1.9 MB. Over BLE that would take minutes.

What you need instead is `includePeerToPeer` in Network.framework.
Bluetooth is used there only to **find** the device, while the data flows
over AWDL — direct Wi-Fi between devices, no router. That is how AirDrop
and Handoff work. No shared network is needed, and the speed is Wi-Fi
speed.

Measured on this channel: 1.86 MB of archive in 66 ms, a state snapshot
in 2 ms.

### The listener is held by the app, not by the daemon

Network.framework is Apple's, and the daemon is written in Node. So p2p
cannot be brought up inside the daemon at all. The listener lives in the
Mac app, which in turn talks to the daemon over `127.0.0.1`.

The consequence — which was the whole point — is that the daemon need not
be on the network at all (`"bindHost": "127.0.0.1"`) and the phone keeps
working.

The price is that the Mac app has to be running. That is exactly why the
daemon watches over it (see below): it went from decorative to the thing
without which the phone sees nothing.

### TLS-PSK: the cipher suite must be set explicitly

There are no certificates here and there must not be: the secret is
carried by eye, from screen to camera. So it is TLS with a pre-shared key
that both sides derive from a password via HMAC-SHA256 (the password
itself is shorter than 32 bytes, and a PSK must be exactly that).

`sec_protocol_options_add_pre_shared_key` alone is not enough: without an
explicit
`sec_protocol_options_append_tls_ciphersuite(…, .AES_128_GCM_SHA256)`
the handshake does not come together at all.

Verified that a wrong password does not get through: the connection dies
with `-9846: bad MAC` during the handshake.

### Continuations in Network.framework do not know about cancellation — and that hangs forever

The most expensive find of all. `PeerTransport` wraps a request in a task
group with a timeout: one task does the exchange, another sleeps and
throws. It looks solid. It does not work.

`withThrowingTaskGroup` waits for **all** child tasks, even after
`cancelAll()`. And the exchange sits on a
`withCheckedThrowingContinuation` around an `NWConnection` callback,
which knows nothing about cancellation. If the Mac has gone to sleep or
the password did not match, the connection is stuck in `.preparing` —
nobody will ever wake the continuation, and the group will never finish.

So there was a timeout, and the request hung forever anyway. On the phone
that would mean a permanently frozen screen.

The cure is `withTaskCancellationHandler`, which on cancellation tears
down the connection itself: it moves to `.cancelled`, the callback fires,
the continuation is released.

### Header and body get separate lengths, and the body stays raw bytes

A frame looks like this:

```
[4 bytes: header length][JSON header][4 bytes: body length][body]
```

The temptation to put the body inside the JSON header is strong, but then
every state snapshot would be re-encoded twice on each side — and it
arrives every two seconds. Raw bytes pass straight through without any
parsing.

Reading collapses into four `receive` calls where `minimum` and `maximum`
are equal: Network.framework delivers exactly as much as you asked for,
and no buffer of our own is needed.

### Both services must be in NSBonjourServices

iOS will not show an app any service that is not in that list — silently,
with no error. So both are listed there: `_laserbeak-p2p._tcp` and
`_laserbeak._tcp`.

They are advertised under a single name (`serviceName` from the config),
so on the phone they merge into one laptop. Because of that the Mac app
reads the same `serviceName` from `config.json` rather than using
`Host.current().localizedName`: that one gives "My MacBook", with a space
where the daemon says "my-macbook".

### An actor is not a queue

`PeerChannel` is an actor, and a comment claimed "requests run one after
another". They do not: an actor re-enters on **every** `await`. So while
one request sat on `receive`, a second walked in and sent its own frame.
Replies were matched up correctly only thanks to the order in which
Network.framework happened to queue the calls — that is, by accident.

It becomes visible where the phone polls two things at once: the state
feed every two seconds and the conversation every two seconds. The frame
has an `id` field, but nobody was checking it.

So now the queue is real: an explicit lock with a queue of continuations
inside the actor. That fixed the timeout as a bonus — it now starts
counting when the request actually goes on the wire, not when it was
created. Previously a state poll with a 5 s timeout could die queued
behind a two-megabyte archive and take the channel down with it.

### Cancelling one request tore the channel down for everyone

`cancellable` tears down the connection on cancellation — otherwise
nobody wakes the continuation (see above). But there is one connection for
everyone: leaving the conversation screen while its request was in flight
was enough for SwiftUI to cancel the task — and the channel fell with it.
The next state poll saw a break out of nowhere.

Now the exchange itself runs as a separate, non-cancellable task: the
frame is read to the end no matter what. It cannot be otherwise —
abandoning a read mid-frame means handing the next request the tail of
somebody else's response.

### Keepalive 2/2/3 broke the connection more often than the network did

It seemed sensible: a break is detected within eight seconds. But AWDL
does not lie flat — the radio is shared with the main Wi-Fi and sleeps
along with the screen, so a pause of a few seconds is normal there. Over
an hour of use the phone reconnected 14 times.

A break will be noticed by the request timeout anyway, so what is needed
here is slack, not vigilance: 10/5/3.

### You can only fall back to where somebody is

A single failure of the direct channel used to enable a minute of "HTTP
fallback". But the daemon listens on `127.0.0.1` only by default and is
not advertised on the network at all — so the fallback went to the
address from the QR code, where nobody answers. The result: one failed
frame bought a minute of blank screen instead of one reconnect.

Now the direct channel is only abandoned if `_laserbeak._tcp` really is
found on the network. And a single failure means nothing at all: the
client reports a break only after two in a row.

### An empty key is not a new key

The app re-reads the key from the daemon every minute so as not to be
left with a stale password. But when the daemon happens to be restarting
(which it does after every edit in `src/`), the request fails and returns
an empty string. The old code would first tear down the listener and only
then notice there was no key — leaving the phone without a channel until
the next check, i.e. for a minute.

No answer means touch nothing.

### The Bonjour browser does not revive itself

After the phone sleeps, `NWBrowser` can wake up `.failed`. The handler
recorded that in `lastError` — and that was all. The laptop vanished from
the list forever, and with it any way to connect: the phone no longer had
anywhere to go.

Now `.failed` restarts the search after three seconds, and returning to
the app (`scenePhase == .active`) verifies that the search is alive at
all.

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

### The overlay has to live in a Shadow DOM

The frame is drawn on top of someone else's page, and out there you meet
both a global `* { box-sizing: border-box }` and a
`div { position: static !important }`. A Shadow DOM with `all: initial`
severs that link in both directions: the page cannot reach us, and we
leave nothing behind in its CSS.

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

### `activeTab` instead of `<all_urls>`

The temptation to ask for access to every page is strong — then it works
everywhere, immediately. But clicking the icon, the keyboard shortcut and
the context menu all grant `activeTab` by **themselves**: permission for
the tab you just acted in, and only for now. The extension never sees the
rest of your pages.

## The access key

### The daemon listened on the network with no protection at all

`bindHost: 0.0.0.0` is needed so the phone can see the daemon. But it
also meant anyone on the Wi-Fi could read `GET /state` — project names,
session labels, history — and, worse, send `POST /sessions/input`
straight into a live Claude Code session.

Now anything not coming from `127.0.0.1` must bring a key. Localhost
requests stayed key-free: only someone already sitting at this computer
can make them.

### The key and the connection password are one and the same

Splitting them into two secrets is tempting, but then the QR code would
have to carry both, and rotating the key would mean syncing two places.
One secret: over HTTP it travels as a header, over p2p it becomes the TLS
password. Transferred exactly once.

### launchd's KeepAlive does not go with launching via `open`

The app now holds the only channel to the phone, so it must always be
alive. `KeepAlive: true` looks sufficient — it is not.

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

### Complaints to the log need muting

Somebody else's script hammering once a second would inflate
`daemon.log` to gigabytes overnight. So at most three complaints are
written per address, and then silence.

## Claude Code's data

### Transcripts live for about 30 days

Verified: 518 MB, 758 files, the oldest exactly 31 days old. So
conversations disappear on their own. Hence the archive.

### The same record appears in a transcript several times

83 duplicates in a real file, all with identical `usage`. Without
deduplication by `message.id` the token count is inflated roughly
one-and-a-half times (73.9M instead of 48.3M).

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

### The model is visible in the transcript, the effort level is not

`tokens.model` comes from the `message.model` field in the transcript,
i.e. it is a fact: what the session actually replied with last. There is
no such field for effort — hence the two different sources for two
adjacent values in the interface.

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

### JetBrains leaves `opened="true"` behind after quitting

The flag in `recentProjects.xml` is not cleared when the IDE is closed.
So it is only honoured for IDEs whose process is currently alive —
otherwise a project from an IntelliJ closed a week ago would hang around
in the list.

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

### Window sizes break the phone

`.frame(minWidth: 540)` is sensible for a window on the Mac, but on the
phone it pushes content off screen — the send button ended up outside the
visible area. Use `.windowSize(...)`.

### Part of the SwiftUI API is macOS-only

`.buttonStyle(.link)`, for example. Check like this, without building:

```bash
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
swiftc -typecheck -sdk "$SDK" -target arm64-apple-ios17.0-simulator \
  app/Shared/*.swift app/iOS/*.swift
```

### Node reads HTTP headers as latin-1

A Cyrillic label (`start "проба"`) arrived as mojibake. You need
`Buffer.from(value, 'latin1').toString('utf8')`.

---

## iPhone

### You need the iOS platform in Xcode

Without it the device shows up as `connected (no DDI)` and the build
fails with `iOS 26.5 is not installed`. Install with:

```bash
xcodebuild -downloadPlatform iOS      # ~8.5 GB
```

### Developer mode on the phone

`Settings → Privacy & Security → Developer Mode`. Without it the build
fails with `Developer Mode disabled`.

### After pairing, the cable is no longer needed

The device stays reachable over Wi-Fi (`transportType: localNetwork`),
and `install-phone.sh` works without wires.

### `devicectl` lists long-forgotten devices

An iPhone 11 paired three months ago was still in the list, and the
script kept picking it. Selection has to go by connection activity and
the freshness of `lastConnectionDate`.

---

## Markdown in conversations

### SwiftUI only handles inline markdown

`AttributedString(markdown:)` gives you bold, italics, code and links.
Headings, lists, tables and code blocks it leaves as-is — which is why raw
`## Appearance` and `| a | b |` were visible in the chat.

Writing our own parser was unavoidable, but it stayed small: first I
counted what actually occurs across 2,402 replies in the archive.

```
inline code `…`  56%     code block ```   7%
bold **…**       47%     list 1.          4%
list -           12%     italics *…*      3%
table |          10%     rule ---         1%
heading ##        9%     quote >          1%
```

So tables occur more often than code blocks — by eye I would have guessed
the opposite. Exactly this set is supported, and parsing costs 0.05 ms per
reply.

### ImageRenderer does not draw the contents of a ScrollView

The most expensive trap in this part. I was checking the appearance by
rendering a bubble to a png — and saw an empty tile instead of a code
block and emptiness instead of a table. I spent half an hour looking for a
layout bug.

There was no bug: `ImageRenderer` simply does not draw what is inside a
`ScrollView`. In the app itself everything was in place. This takes a
minute to check — render a `ScrollView { Text("something") }` next to a
plain `Text`.

The moral is broader than this case: when your test rig shows emptiness,
first ask whether the rig can see anything at all.

### The heading was smaller than the body text

`.subheadline` is 15pt, and `.callout`, which the body is set in, is 16pt.
A second-level heading came out smaller than an ordinary paragraph, so the
hierarchy worked backwards. Types show nothing of this; I only saw it by
eye, on a rendered image.

### A UUID as an identifier breaks SwiftUI silently

Blocks and list items initially had `let id = UUID()`. It looks harmless,
but parsing happens on every redraw — so fresh identifiers were born each
time, and SwiftUI considered the list to be entirely different.

Blocks are defined by their position in the text, so they must be
enumerated by index.

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
