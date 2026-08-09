> [!WARNING]
> **EXPERIMENTAL.** Loupe works, and it is young: the API, the CLI verbs and the
> on-disk formats will change without notice, and the simulator bridge in
> particular has been exercised against a handful of apps rather than many. It
> drives real applications on your Mac — read what a command does before running
> it. Issues and findings are welcome; compatibility promises are not implied.

# Loupe

Look at and drive UI — **web pages, Mac apps, iOS simulators** — from a CLI or an
MCP tool call, and get before/after proof images out the other end.

Loupe never takes over your screen. Mac windows are read and driven through the
accessibility API and captured with ScreenCaptureKit, so they work while
occluded, minimized, or hidden, and the app is never brought to the front. Web
pages render in a web view that is never ordered on screen. Simulators run
headless — Simulator.app never has to open. You keep using your Mac while an
agent works.

A loupe is what you bring *to* the object to inspect it closely. You never move
the object.

```bash
# hold a target open, then step through a flow
loupe use "mac:MyApp#main" --session
loupe describe
loupe set login.username admin
loupe set login.password '{{APP_PASSWORD}}'
loupe press login.submit
loupe wait 'Dashboard|!Invalid password'
loupe capture --out after.png

# what can I point it at?
loupe list

# screenshot anything
loupe capture https://example.com
loupe capture mac:Safari
loupe capture sim:booted

# read the element tree instead of guessing at pixels
loupe describe mac:TextEdit --filter Save

# drive it
loupe act https://example.com --press "More information" --out after.png

# prove a fix, across two invocations and a rebuild
loupe before issue-517 mac:MyApp
#   …fix the bug, rebuild, relaunch…
loupe after  issue-517
#   → ~/.loupe/sessions/issue-517/compare.png
```

`after` writes a side-by-side image, BEFORE next to AFTER, with the regions that
actually changed boxed in red, plus a one-line summary of how much changed. That
image is the thing you attach to an issue or a merge request.

## Scripting it in the XCUITest API

A flow with real control flow — retries, branches, conditions — is awkward as a
sequence of CLI calls and expensive as a sequence of agent turns. Write it as one
script instead, in the API the app's own UI tests already use:

```swift
import XCUIAutomation

let app = XCUIApplication(bundleIdentifier: "com.example.MyApp")
app.launch()
app.textFields["username"].typeText("admin")
app.secureTextFields["password"].typeText(env("APP_PASSWORD"))
app.buttons["Sign In"].tap()
XCTAssertTrue(app.staticTexts["Dashboard"].waitForExistence(timeout: 10))
```

```bash
loupe script login.swift --screenshots ./proof
```

That file is not a Loupe dialect — it is a UI test. `import XCUIAutomation`
resolves to Apple's framework when the file is compiled into a test target, and
to Loupe's drivers when it is interpreted here, so a flow proven by hand pastes
into a test target unchanged. Unlike a real test it needs no runner and no test
bundle, starts in under a second, and drives whatever is already running.

See [Docs/xcui-scripts.md](Docs/xcui-scripts.md) for the covered API, the
additions worth having (`waitForExistence(timeout:orFailure:)`,
`waitUntil(labelContains:)`, `setText`, `scrollToVisible`), and every place the
surface knowingly departs from Apple's — also printed by
`loupe script --divergences`.

## Driving your own app while you build it

If you are an agent (or working with one), [SKILL.md](SKILL.md) is the short
version: how to check UI work by driving the running app instead of guessing —
look, change, look again — and how to produce proof that a fix worked.

[Examples/TaskDemo](Examples/TaskDemo) is a small universal SwiftUI app with the
check written the way an agent would write it, running unchanged on iPhone and
iPad.

## Why it exists

Agents that fix UI bugs cannot show their work. They can describe a change, but
"trust me, the totals line up now" is not evidence. Loupe gives an agent the two
screenshots and the diff, in a form that pastes into a code-review conversation.

The constraint that shapes everything: it has to work while a human is using the
same Mac. An automation tool that steals focus, moves the cursor, or blocks the
screen can only run when nobody is there.

## Targets

One syntax across all three surfaces:

| Target | Meaning |
| --- | --- |
| `https://example.com` | a page in an offscreen web view (bare URLs imply `web:`) |
| `web:<url>` | the same, spelled out |
| `mac:Safari` | an app's frontmost window, by name |
| `mac:com.apple.Safari` | …or by bundle id |
| `mac:pid:4711` | …or by process id |
| `mac:Safari#2` | that app's window at index 2 |
| `mac:MyApp#main` | …or the window whose title or identifier contains this |
| `sim:booted` | the booted simulator |
| `sim:iPhone 17 Pro` | a simulator by name |
| `sim:6805ED2E-…` | …or by udid |
| `@portal` | a live session held open in its own process |

## Looking, deciding, acting

An agent fixing a UI bug does not know its steps in advance: it looks, decides,
acts, and looks again. Mac apps and simulators support that with no ceremony —
the app itself holds the state and outlives your commands:

```bash
loupe describe mac:Calculator --depth 12 --all   # what can I press?
loupe act mac:Calculator --press Seven           # decide, act
loupe describe mac:Calculator --filter "Edit field"   # look again
```

A web page has no such owner: its web view dies with the process, so every
command would reload it. Open a live session and it stays put:

```bash
loupe session open http://localhost:3000/login --as portal
loupe describe @portal                                  # find the fields
loupe act @portal --step 'set:username=…' --step 'set:password=…' --step 'press:Login'
loupe describe @portal                                  # still logged in
loupe session close portal
```

### Secrets

Never put a password on the command line — `ps` shows `argv` to every process on
the machine, and your shell writes it to history. Reference the environment
instead:

```bash
export PORTAL_PASSWORD='…'
loupe act @portal --step 'set:username={{USERID}}' --step 'set:password={{PORTAL_PASSWORD}}' --step 'press:Login'
```

Braces, not `$`, for two reasons: the shell never touches `{{…}}` in any quoting
style, so the secret cannot leak into `argv` by accident; and `$3.94` is an
ordinary value in a tool built for checking totals. Values that came from the
environment are also scrubbed from everything Loupe prints or returns — otherwise
protecting the input and then echoing "set password to hunter2" would be theatre.

A missing variable is an **error**, never a passthrough: substituting the literal
`{{NAME}}` would type it into the field, and the resulting failure would look
like a bad selector rather than a missing secret. When a value is genuinely
optional, say so — `{{NAME:-fallback}}`, or `{{NAME:-}}` for "blank is fine".

Best of all, for repeat runs: log in **once** into a named `--profile` or a live
session, and later runs never touch credentials at all.

Each verb is its own command — `press`, `set`, `type`, `key`, `open`, `tap`,
`reveal`, `wait` — taking its arguments as arguments, and defaulting to the
target set by `loupe use`. That is the shape for stepping through a flow, where
you decide the next move from what the last one showed.

`loupe act --step 'press:Save'` says the same thing, packing the verb and its
argument into one shell word. That is the right shape for an ordered *batch*
(one process, state preserved between steps, good for scripts) and the wrong
shape for a single step, where it is a small language living inside `argv` with
its own quoting and nested delimiters. Both exist; use whichever fits.

A session is one helper process, not a system daemon: started on demand, gone
after 15 idle minutes, and the same signed binary, so it needs no separate
permissions. `loupe use <target> --session` opens one and remembers it in a
single step, naming it after the target (`@login`, `@safari`, `@iphone-17-pro`)
so the same target always maps to the same session.

Sessions are not web-only — they hold a Mac app or a simulator just as well.
There the app already outlives your commands, so a session buys less, but it
keeps a resolved window and a warm accessibility tree, and `--session <name>`
routes a single command to one without disturbing whatever `use` remembers:

```bash
loupe describe --session login       # this one call goes to @login
```

Precedence is most-specific-wins: an explicit target, then `--session`, then the
remembered one.

## What each surface can do

|  | web | mac | simulator |
| --- | :-: | :-: | :-: |
| Screenshot | ✅ | ✅ (even occluded/minimized/hidden) | ✅ |
| Full-page screenshot | ✅ | — | — |
| Element tree | ✅ (DOM) | ✅ (accessibility, incl. menu bar) | ✅ (XCUITest) ² |
| Press / click | ✅ | ✅ | ✅ ² |
| Set value | ✅ | ✅ (full Unicode, atomic) | ✅ ² |
| Type / keys | ✅ | ✅ | ✅ ² |
| Swipe / scroll | ✅ | ✅ | ✅ ² |
| Navigate / deep link | ✅ | ✅ | ✅ |
| Launch app | — | ✅ (without activating) | ✅ |
| Run JavaScript | ✅ | — | — |
| Live session (`@name`) | ✅ | ✅ ¹ | ✅ ¹ |
| Never disturbs the user | ✅ | ✅ | ✅ |

¹ Supported, but rarely needed: a Mac app and a simulator already outlive your
commands.

² Through a UI-test bundle Loupe builds once and installs on the device, which
then answers over loopback. `simctl` exposes no elements at all, and the
accessibility Simulator.app forwards to macOS is flattened past usefulness — a
tab bar arrives as a childless group — so XCUITest is the only complete view.
Because a UI-test bundle needs no test host, one runner drives every installed
app on every booted device. First use costs a build (~40 s, then cached in
`~/.loupe/bridge`); a session starts in about three seconds. See
[Docs/xcui-scripts.md](Docs/xcui-scripts.md).

### Apps with poor accessibility

Poor accessibility almost never means *missing* elements. A button is an AX
element with a role, a frame and `AXPress` whether or not anyone gave it a label
— what is missing is a **name to address it by**. So the fix is not to abandon
accessibility for pixels; it is to identify the element visually and then act on
it through accessibility as usual.

```bash
loupe capture mac:MyApp --annotate --out ui.png
#   1. textfield "Username"      → w0/g0/g0/f4
#   2. button "Show password"    → w0/g0/g0/b6
#   3. button                    → w0/b1
loupe act mac:MyApp --step 'press:w0/b1'
```

`--annotate` boxes and numbers every actionable element and prints a legend, so
a model reads "3" off the picture and acts on a handle from the tree. The
perception can be approximate; the action is exact. Containers are skipped (their
boxes would swallow the controls inside), disabled controls are shown and marked,
and the menu bar is left out since it is not in a window capture.

To check your aim before committing to anything:

```bash
loupe at mac:MyApp n:0.56,0.63
#   button
#     handle: w0/b1
#     actions: AXPress
#     frame: x=316 y=229 w=16 h=16
```

Loupe also reads `AXRoleDescription` when a control has no title, which recovers
names like "full screen button" and "scroll area" that would otherwise show as
nameless — worth knowing before reaching for coordinates at all.

### Clicking by coordinate

Sometimes you have a point rather than an element. `click:` still goes through
accessibility — it hit-tests the coordinate and presses (or selects) whatever is
there, needing no label and moving nothing on screen. The hard part is saying
*which* coordinates, so the space is explicit:

```bash
loupe act mac:MyApp --step 'click:120,340'          # window points (default)
loupe act mac:MyApp --step 'click:px:240,680'       # pixels of a full-res capture
loupe act mac:MyApp --step 'click:n:0.5,0.33'       # fraction of the window
loupe act mac:MyApp --step 'click:screen:1500,900'  # global screen points
```

**Use `n:` when working from a screenshot you were handed.** It is the only space
that survives rescaling — and images delivered over MCP are downscaled to keep
the token cost sane, so their pixels are neither window points nor capture
pixels. Pixel space uses the *actual* display's backing scale, not an assumed 2,
because a window on a non-Retina monitor would otherwise be clicked at double the
offset.

A coordinate click still goes through accessibility: it hit-tests the point and
presses (or selects) whatever is there, so it needs no label — only that
something at that point is actionable. Nothing moves on screen.

When even that fails, `cursorclick:` is the last resort:

```bash
loupe act mac:MyApp --step 'cursorclick:n:0.5,0.5'
```

This is the one action in Loupe the user can see, so it is never a silent
fallback. It does *not* try to activate the app first: macOS ignores activation
requests from a background process — `NSRunningApplication.activate()` returns
`true` and setting `AXFrontmost` returns success while nothing happens — so that
cannot be made reliable from a CLI. It is also unnecessary, since clicking a
visible window focuses it exactly as a user's click would.

What it does insist on is that the target really is the **topmost window at that
point**, and refuses otherwise:

```
Error: refusing to click at (1519, 860): the topmost window there belongs to Finder,
not a real SwiftUI Mac app. A real click goes to whatever is visible, so this would have hit
the wrong app.
```

Without that check, a click aimed at a covered window lands on whatever is over
it — the user's own app, doing something nobody asked for. Only normal windows
(layer 0) count as occluders; the Dock owns a full-screen window at layer 20 that
would otherwise make every click look blocked. The pointer is moved and put back;
focus stays where the click left it, because that is what a click does.

### Scrolling

Two verbs, and the second is usually the one you want:

```bash
loupe act mac:MyApp --step 'scroll:0,-400'      # by a distance, in points
loupe act mac:MyApp --step 'scrollto:Save'      # reveal a specific element
```

`scrollto` (alias `reveal`) asks the app to bring an element into view —
`AXScrollToVisible` on macOS, the action VoiceOver uses to follow focus, and
`scrollIntoView` on the web. That beats guessing a distance, and it works inside
nested scrollers where a distance-based scroll would move the wrong one. Where
an app does not implement the action, Loupe falls back to computing the
scroll-bar position from the element's own frame.

Distance scrolling on macOS positions the scroll bar directly rather than
synthesizing wheel events: macOS delivers scroll wheels only to the frontmost
app, which would take the user's focus. It reports how far it *actually* moved,
because a scroll that silently does nothing leaves you screenshotting the same
view and concluding the content is not there:

```
scrolled vertically by 340 points of the 400 requested (scroll bar 0.120 → 0.395 of a 1236 point range)
```

Simulators swipe instead: the bridge sends a real drag through `XCUICoordinate`, so momentum and rubber-banding behave as they would under a finger.

### Waiting for the right thing

`settle` watches pixels, which is blunt: a spinner never settles, and a screen
that paints in two passes looks settled between them. Wait on the element
instead — and, crucially, race it against the failures you expect:

```bash
loupe act mac:MyApp \
  --step 'set:login.username=admin' --step 'key:tab' --step 'type:{{APP_PASSWORD}}' \
  --step 'press:login.submit' \
  --step 'await:Health Dashboard|!Invalid|!failed@20'
```

`await:A|B` returns as soon as either appears. A `!` prefix marks a *failure*
condition: if it matches, the step throws immediately, quoting what the app
said. Measured on a real login, a wrong password failed in **under a second**
with "Invalid username or password." — where waiting for the dashboard alone
would have burned the full 20 seconds and then reported a timeout, the least
useful description of what happened.

`await` also requires the element to be **enabled**, not merely present, since
acting on a disabled control is a no-op that reports success.
`gone:Loading` waits for something to disappear. `@30` overrides the timeout.

### Secure fields need typing

`setValue` writes straight to an element's accessibility value: atomic, full
Unicode, no focus required, and it does reach a SwiftUI `@State` binding — a
form's validation re-runs and dependent buttons enable, verified on a real
SwiftUI login screen.

The exception is **secure text fields**. macOS refuses to expose or set their
value, so the write appears to succeed and the field still reads back empty.
Loupe treats that as a failure rather than reporting success:

```
Error: AXValue on AXTextField 'Password' was accepted but the element now reads ''
instead of '…' — the app reformatted or rejected the value.
```

Type into those instead — real key events go through the normal input path:

```bash
loupe act mac:MyApp --step 'set:login.username=demo' --step 'key:tab' --step 'type:{{APP_PASSWORD}}'
```

This is also why `setValue` verifies by reading back: without it, a password
field would silently stay empty and the failure would surface much later as a
rejected login.

### Windows

```bash
loupe window close mac:Safari#0
loupe window minimize mac:Preview
loupe window raise mac:Notes        # forward within its app, without activating it
```

**Loupe never sends Apple Events.** macOS Automation consent is per-application
and blocks on a user prompt — so the first `osascript` call against a new app
either stops for a dialog or, headless, hangs until it times out. That makes
AppleScript unusable for anything unattended, which is most of what this tool is
for. Everything here is accessibility plus `NSWorkspace`, neither of which
prompts. If you see a "wants access to control" dialog while using Loupe, it did
not come from Loupe.

A related lesson worth keeping: when accessibility and AppleScript disagree about
what windows exist, accessibility is usually right. Safari can keep an empty
phantom window object that its AppleScript dictionary still lists and that
`close` silently ignores; `loupe list` correctly does not show it.

## Making comparisons trustworthy

A diff tool that cries wolf is worse than none. Loupe defaults to:

- **Settling** before every capture — it waits for the screen to stop changing,
  because animation is the main source of false differences.
- **A per-channel tolerance** of 4/255 rather than byte equality. Two renders of
  an identical page can differ on most pixels by 1–3/255 from gradient
  dithering; a hash comparison calls that a change, an eye does not.
- **Frozen simulator status bars** (`loupe sim status-bar`) — a ticking clock
  changes pixels by itself.
- **Blocked media autoplay** in web captures, so a hero video is not caught at a
  different frame each run.
- **Warning when nothing changed**, because an identical "after" usually means
  the fix is not in the running build, not that the fix is invisible.

## MCP

```bash
loupe mcp    # stdio MCP server
```

Tools: `loupe_list_targets`, `loupe_capture`, `loupe_describe`, `loupe_act`,
`loupe_eval`, `loupe_before`, `loupe_after`, `loupe_diff_report`, `loupe_compare`,
`loupe_session_open`, `loupe_session_list`, `loupe_session_close`,
`loupe_sim_status_bar`, `loupe_sim_appearance`, `loupe_doctor`. Images come back inline as content
blocks (downscaled, since a full 5K capture costs ~2,500 image tokens).

Wire it into any ACP agent, for example in `~/.acpx/config.json`:

```json
{ "mcpServers": [ { "name": "loupe", "command": "/usr/local/bin/loupe", "args": ["mcp"] } ] }
```

## Permissions

```bash
loupe doctor
```

- **Web** — nothing. No grants at all.
- **Mac** — Accessibility (read the tree, press things) and Screen Recording
  (window screenshots). Grants bind to the code signature, so sign the binary
  with a stable identity or you will re-grant after every rebuild.
- **Simulator** — Xcode's `simctl`. No TCC grants.

Run it as a LaunchAgent in the user's GUI session, not a root LaunchDaemon:
Accessibility and Screen Recording are session-scoped.

## Requirements

macOS 14+, Swift 6. Xcode for the simulator surface. No third-party
dependencies beyond `swift-argument-parser` and `SwiftMCP`.

## Design notes

Everything here was settled empirically rather than from documentation, because
most of this area is folklore:

- Safari and WKWebView load the **identical** WebKit binary. Using real Safari
  via `safaridriver` buys no engine fidelity, and costs a visible window, a
  machine-wide single-session lock, and a clean-slate profile with no logins.
- `element.click()` fires **one** event where a real click fires eleven, and it
  clicks straight through blocking overlays — so a cookie banner that would stop
  a human is invisible to a naive test. Loupe dispatches the full pointer
  sequence and hit-tests with `elementFromPoint` first.
- `CGEvent.postToPid` mouse events do not work on AppKit apps at all, even when
  the app is frontmost — they arrive with no window and get dropped. Accessibility
  actions are the only reliable path, and they happen to be the non-intrusive one.
- On macOS, `AXUIElementPerformAction` on a **disabled** menu item returns
  *success* and does nothing. Loupe checks `AXEnabled` first, because a silent
  no-op is the worst failure mode a verification tool can have.

## License

MIT — see [LICENSE](LICENSE).
