# Status

Verified end-to-end on macOS 26.6 / Xcode 26.4 / Swift 6.3 (2026-08-08).

## Working

| Surface | Verified |
| --- | --- |
| **web** | capture 1280×900pt @2x in **1.2 s**; DOM tree; press dispatching all **11** pointer events with an `elementFromPoint` hit-test; before/after with a real fix |
| **mac** | describe + capture of a **background** TextEdit; `setValue` with emoji and Japanese, read-back verified; before/after composite. **Frontmost never changed** across every operation |
| **sim** | 402×874pt @3x capture of the booted iPhone 17 Pro in ~3 s; deep-link navigation; status-bar freeze (clock read 09:41 in both panels of a comparison) |
| **CLI** | all subcommands; `doctor` reports all three surfaces green |
| **MCP** | 12 tools over stdio, schemas verified via `tools/list` |
| **live sessions** | opened in 1.1 s; login performed in one process and the Dashboard observed from another; `list`/`close` and post-close errors verified |
| **secrets** | `{{NAME}}` read from the environment, verified end to end: login succeeded, the value never appeared in output, and a missing variable failed with an actionable error |
| **tests** | 37 passing |

## Two findings worth keeping

**The diff is sharper than expected.** Changing `$3.88` → `$3.94` in a right-aligned
table flagged *four* regions, not one. That was correct: the digits have different
advance widths, so the whole column reflowed by a pixel or two. Confirmed by a
control run — changing only a CSS color flags exactly one region. The tolerance is
doing its job at both ends: it absorbs dithering but not a sub-pixel layout shift.

**Sessions must store the target as written.** The first `mac:` round-trip failed
because the session had recorded the driver's *resolved* description
(`mac:TextEdit#0 'note.txt' (pid 71894)`), which is for humans and whose pid is
meaningless after a relaunch. Sessions now keep both: `target` (re-parseable) and
`resolved` (for the caption).

**Ordering was a real bug, not a wart.** The first login attempt failed because
the shorthand flags grouped by kind and ran `--press Login` *before* `--set`,
submitting an empty form. Fixed twice over: the shorthand order is now
fill-then-submit, and `--step kind:arg` preserves exactly what you wrote.

**Two bugs the live-session work surfaced**, both invisible to unit tests:
an undrained `Pipe` on the child process deadlocked it once WebKit filled the
64 KB buffer (now a log file), and `save` encoded dates as ISO-8601 while `load`
used a default decoder, so every healthy session read as dead.

**Driving real Safari works.** Crawled a five-page intranet through Safari
itself: opened a new window from Safari's own menu bar, followed the pages' links,
read content from the `AXWebArea` tree, and captured each screen — all with Safari
in the background and the user's 19-tab window untouched. Two things learned:
setting the address bar and pressing Return only navigates the *first* time
(afterwards focus is in the web content, so press the page's own links instead),
and `AXWindows` lists only the current Space's windows, so a window can leave the
list and shift the `#N` indices under you — resolve by title before acting.

**A locked Mac is a real operating condition.** Testing against the the app
Admin app happened to run with the screen locked, which turned out to be
informative: launching an app and driving it over accessibility both keep
working, but ScreenCaptureKit refuses with "Failed to start stream due to
audio/video capture failure" — an error that tells the caller nothing. Loupe now
detects the lock and says so, and `doctor` reports it as a warning.

**Driving a real SwiftUI Mac app** (a real SwiftUI Mac app): launched it into the
background, read a tree with proper accessibility identifiers
(`admin.login.username`, `admin.login.submit`), captured it while Claude stayed
frontmost, and produced a before/after of the sign-in form going from empty with
Sign In disabled to filled with Sign In enabled.

The finding worth keeping: **macOS will not let accessibility set a secure text
field.** The write is accepted and the field still reads back empty, so the
password step failed while the username step succeeded — which is exactly why
`setValue` verifies by read-back rather than trusting the API's return code.
Type into secure fields instead.

(An earlier reading of this — that SwiftUI bindings ignore `setValue` — was
wrong, and the retest is worth recording: `setValue` on the username plus a
typed password enabled Sign In, so a successful `setValue` does reach the
binding and re-run validation.)

**Logged into and navigated a real SwiftUI app.** Signed into a real SwiftUI Mac app with
its documented dev credentials and walked all 14 sidebar sections, each verified
by the window title changing (Queue, Content Browser, Worksheet, Organizations,
Jobs (4), Images (0), Review (0), Billing Reports, Pricing, Prompt Templates,
Daemon Settings, Log Viewer, Rate Limits, About) — all in the background.

Three fixes came out of it, each a silent-no-op of the kind this tool exists to
prevent:

1. **SwiftUI list rows expose no `AXPress`** — only `AXShowDefaultUI`. They are
   activated by *selection*. `press` now falls back to setting `AXSelected` on
   the nearest ancestor whose role is actually a row: a static text inside a row
   reports selection as settable and then ignores the write, so the role check
   and the read-back are both load-bearing.
2. **Window indices are not stable.** A password-autofill popup took index 0
   mid-flow. Targets accept `#<title-or-identifier>`, and identifiers are matched
   because a title often tracks the current screen while the identifier does not.
3. **Labels sit inside the clickable element.** `press` climbs to the nearest
   pressable ancestor rather than failing on the static text that matched.

**Coordinate clicking** now names its space (`click:120,340`, `px:`, `n:`,
`screen:`), with the conversion extracted into pure arithmetic in `LoupeCore` and
unit-tested — an off-by-one scale factor puts every click at double or half the
intended position, which is not something to discover against a user's app. The
`n:` space exists because MCP downscales images, so a model's pixel coordinates
match neither points nor capture pixels; a fraction of the window survives any
rescaling. `cursorclick:` is the opt-in real click for UI accessibility cannot
reach, and is the only visible-to-the-user action in the tool.

Verified live: the centre of one button expressed as `screen:1518.5,860.5`,
`1210.5,639.5`, `px:2421,1279` and `n:0.5612,0.62573` all resolved to the same
screen point and pressed the same control — the label alternating
Show/Hide/Show/Hide proving each of the four clicks actually landed.

`cursorclick` was verified too, including its refusal: covered by a Finder
window it declined and named the blocker; on a visible part of the window it
clicked, brought the app forward as a real click does, and restored the pointer.

Two findings from that work: **macOS ignores activation from a background
process** — `NSRunningApplication.activate()` returns true and `AXFrontmost`
returns success while nothing moves — so `cursorclick` verifies the target is
topmost instead of trying to activate it. And **only layer-0 windows can
occlude**: the Dock owns a full-screen window at layer 20 that otherwise makes
every click look blocked.

**Bridging vision and accessibility.** `capture --annotate` boxes and numbers
actionable elements with a legend mapping each number to its handle, and
`loupe at <target> <point>` reports what is at a coordinate without touching it.
Both exist for the same reason: an app with "poor accessibility" usually has
perfectly good elements that simply lack labels, so the missing piece is
addressing, not acting. Verified on a real login window — the unlabelled window
controls were numbered, probed by point, and pressed by handle.

That also exposed a labelling gap worth more than the annotation itself:
`describe` stopped at `AXTitle`/`AXDescription` while the press path also
consulted `AXRoleDescription`, so controls whose only name lives there ("full
screen button", "scroll area") were reported as nameless. It is now used as a
last resort, and skipped when it merely repeats the role.

**Scrolling by element.** `scrollto:<element>` (alias `reveal`) asks the app to
bring something into view — `AXScrollToVisible` on macOS, `scrollIntoView` on the
web — rather than guessing a distance, with a scroll-bar-position fallback where
the action is unimplemented. Verified on the web: scroll position went 0 → 1769
to reveal an off-screen button. The macOS path is implemented and compiles but is
**not yet verified live**; see below.

**The Spaces limitation deserves a fix, not another note.** Accessibility lists
only windows on the current Space, so an app in full screen or on another desktop
looks like an app with no windows. It cost time four separate times in this
session, including blocking the macOS `scrollto` verification. The error now
consults the window server and says which case it is — "has 1 window(s) —
'MyApp 1.0.0-alpha' — but none on the current Space" — which at least
makes it actionable.

**The simulator leg, tested on a real app** (a real SwiftUI iOS app):
launched by bundle id, status bar frozen, captured at 402×874pt @3x, and a
light/dark before/after produced a correct side-by-side. Everything the sim
surface claims to do, it does.

What it cannot do became concrete. `describe` refuses as designed, and the one
public navigation mechanism — `simctl openurl` — failed with `-10814` because
**the app registers no `CFBundleURLTypes`**. It handles `myapp://` links
internally but never declares the scheme, so nothing outside can open them. For
that app on the simulator, Loupe can launch and photograph and nothing else.

That is the sharpest argument yet for the XCUITest runner bridge: deep links only
help apps that opted into them, and most apps have not.

**Incremental use got its own shape.** Stepping through a flow previously meant
repeating a quoted target on every command and encoding each action as
`--step kind:arg` — a mini-language inside `argv`. Now `loupe use <target>`
remembers the target on disk (so it survives across shells, and across an agent
running each step as its own process), and every verb is a real subcommand:

    loupe use "mac:MyApp#main"
    loupe set login.username admin
    loupe press login.submit
    loupe wait 'Dashboard|!Invalid password'

`act --step` remains for ordered batches in one process, which is what scripts
and web flows still want.

**Sessions became the ergonomic path rather than a workaround.**
`loupe use <target> --session` opens a live session and remembers it in one
step, auto-named after the target; `--session <name>` routes a single command to
one; `session open` now remembers what it opened by default, since opening a
session and then not using it is almost never the intent. Verified end to end on
a multi-step login.

Worth recording: a live session already held *any* surface, not just web — the
capability existed, it was simply undiscoverable. Most of this change is
surfacing it.

**A SwiftScript bridge is designed but not built** — see
[xcui-scripts.md](xcui-scripts.md). The finding worth recording: it
needs **nothing from SwiftScript's module API**, which is already public and
sufficient (`BuiltinModule`, `registerOnImport`, the `bridges` table,
`Value.opaque`). It is blocked instead on a Foundation gap — SwiftScript has no
sleep of any kind, so a script cannot poll or retry, and polling is most of what
UI automation is. Tracked upstream in SwiftScript#7.

## Known gaps

- **A live session pins the binary it started with.** `session open` spawns a
  detached server, so rebuilding Loupe does not change what an open session runs.
  Reopen the session after a rebuild — otherwise a fix appears not to work, which
  cost two debugging cycles to notice.

- **A real Swift Testing file still cannot be pasted in and run** — `#expect`
  and `#require` are macro expansions the interpreter cannot evaluate, and
  `@Test` / `@Suite` are refused as unknown attributes
  ([SwiftScript#14](https://github.com/Cocoanetics/SwiftScript/issues/14)). The
  XCTest spellings work today, with Swift Testing's record-and-continue model.
- **Context menus** — `rightClick()` raises rather than working, because no
  `UIAction` can express a secondary click. Five uses in the surveyed corpus, so
  it is the most-missed of the unavailable gestures.
- **Simulator interaction now works** via the XCUITest bridge (`Bridge`), which
  is the only route that sees a complete tree. What remains: the runner is built
  on first use (~40 s once, then cached in `~/.loupe/bridge`), and it depends on
  two undocumented behaviours — XCTRunner bootstrapping itself without an
  `XCTestConfiguration`, and the `SIMCTL_CHILD_DYLD_*` paths. The documented
  fallback if either breaks is `xcodebuild test-without-building`, which reaches
  the same live bridge.
- **Offscreen pages do not animate.** A never-ordered window puts WebKit in its
  hidden activity state: `requestAnimationFrame` never fires and CSS animations
  stay at frame 0, so canvas/WebGL/chart content is captured at its first frame.
  The driver probes for this and adds a note rather than passing off a frozen
  frame as live. It also makes web diffs unusually free of animation noise.
- **CSS `:hover` cannot be synthesized** — hover *events* fire (JS menus open) but
  hover *styling* is engine-driven off real hit testing.
- Cross-origin iframes and closed shadow roots are not walked; both are reported.
- `loupe window raise` fails on some windows with `AXError -25205` (the window
  does not advertise AXRaise); there is no fallback yet, which matters because
  raising is the documented way to unblock a refused `cursorclick`.
- `type` names the element that was focused when the action was resolved, so
  after a `key:tab` it can report the previous field while the text correctly
  goes to the new one.
- With the screen locked, `capture` is unavailable on the mac surface and window
  *contents* are absent from the accessibility tree (the menu bar still is).
  `describe` and actions keep working; web and simulator targets are unaffected.
- `loupe act` on a Safari address bar navigates only when the field already has
  focus; use the page's links, or focus the field first.
- Interpolation treats every substituted value as sensitive, so a non-secret
  `{{USERID}}` is masked in output too. Conservative on purpose; splitting
  secret from non-secret references would need a second syntax for little gain.
