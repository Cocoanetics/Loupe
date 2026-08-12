---
name: loupe
description: Check your own UI work by driving the running app — web pages, Mac apps, iPhone and iPad simulators — and looking at what actually happened. Use after implementing or changing UI, when a bug is described in terms of what is on screen, or when you need visual proof a fix worked.
---

# Checking your own UI work with Loupe

You changed some UI. The code compiles and the tests pass. Neither of those tells
you whether the screen is right.

Loupe closes that loop: drive the running app, read the element tree, and compare
before against after. It works while someone else is using the same Mac — nothing
is brought forward, the pointer never moves — so you can check your work without
taking over the machine.

## The loop

**Look → change → look again.** Not "write a test suite". You are course-correcting
while you work, and the cost of one check should be seconds.

```bash
loupe describe web:http://localhost:3000   # what is actually there?
loupe press "Sign In"                      # do the thing
loupe capture --out after.png              # look
```

Set the target once and the rest is terse:

```bash
loupe use "mac:My App#main"
loupe describe
loupe set login.username admin
loupe press login.submit
loupe wait 'Dashboard|!Invalid password'
```

## Start by looking, never by guessing

The first command against anything new is `describe`. It prints the element tree
with the handle for every element, so you address things by name instead of by
coordinate:

```
group #Tasks
  button "Add Task" #add-task
  list
    button "Task 1, Notes for task 1" #task-1
```

**The answer arrives in layers, so the first look is cheap.** A line like this
means there is more underneath, and it hands you the call that opens it:

```
list "Sidebar"  [w0/g0/l0]
  … 14 children not expanded — depth cap reached  (describe at w0/g0/l0)
```

```bash
loupe describe --at w0/g0/l0
```

Nothing is ever dropped in silence. If a branch is missing from the output it is
named and counted first, so "there is nothing here" and "you did not ask deep
enough" never look alike — they call for opposite next moves.

On macOS the menu bar arrives collapsed to one line per menu, with each menu's
item count, because on a real app it was 73% of the whole answer and almost never
the thing being asked about. Open one with `describe --at mb/i3`, or pass
`--menus` for all of them. Resolution is unaffected: `press "Quit"` still finds
menu items, and so does `--filter`, which always searches everywhere.

Two things the outline leaves out, both a flag away:

- **What an element can do** — `--actions`. Off by default because most of it is
  chrome repeated on every container. Turn it on when a `press` did nothing and
  you need to know whether the control even claims to support it.
- **Frames** — `--json`, which carries everything: coordinates, native roles,
  the lot, at about four times the bytes.

Anything with a `#` has an accessibility identifier — use that. It survives copy
changes and translation; a visible label does not.

Read the identifier before trusting it, though. A web-based app often exposes
framework-generated ones like `#_r_1r_`, which change between renders and are
worse than the label. A hand-written identifier is the best handle available; a
generated one is a signal to use the label and assert more carefully.

If `describe` shows an element you cannot address, that is a finding about *your
app*, not about Loupe. An element with no label and no identifier is invisible to
VoiceOver too. Fix it in the app.

## Prove the change, do not just claim it

```bash
loupe before totals-fix "mac:My App"
#   …make the change, rebuild, relaunch…
loupe after totals-fix
#   → ~/.loupe/sessions/totals-fix/compare.png
```

`after` writes a side-by-side image with the changed regions boxed and a one-line
summary of how much moved. Attach that to the PR. "Trust me, it lines up now" is
not evidence.

From a script the same thing reads:

```swift
app.captureBefore(named: "totals-fix")
app.buttons["Recalculate"].tap()
let proof = app.captureAfter(named: "totals-fix")
print(proof.summary)   // 0.10% of pixels differ, max channel delta 255, 1 region(s)
```

## Flows worth repeating go in a script

When a check is more than three commands, write it in the XCUITest API. It is the
same source a UI test would contain — `import XCUIAutomation` resolves to Apple's
framework when compiled into a test target and to Loupe's drivers when
interpreted — so a flow you proved by hand pastes into a real test unchanged.

```swift
import XCUIAutomation

let app = XCUIApplication(bundleIdentifier: "com.example.MyApp")
app.launch()

XCTAssertTrue(app.buttons["task-1"].waitForExistence(timeout: 20), "list never appeared")
app.buttons["task-1"].tap()
app.buttons["toggle-done"].tap()
XCTAssertTrue(app.staticTexts["Done"].waitForExistence(timeout: 10))
```

```bash
loupe script check.swift --target "sim:iPhone 17 Pro"
```

Driving Loupe over MCP instead of a shell? `loupe_script` takes the same flow —
as `source` inline or a `path` to a file — and hands back JSON with `status`,
what the script printed, and the failures. Prefer it over a chain of `loupe_act`
calls once a flow needs to wait, branch, or read a value back: those calls each
get their own session, so a web page reloads between them and throws away what
the last one did.

A failed expectation **records and keeps going**, so one run reports every problem
it found rather than dying at the first:

```
check.swift FAILED after 2.3s
  ✗ check.swift:7:1: error: dashboard did not appear
     6 | app.buttons["task-1"].tap()
     7 | XCTAssertTrue(dashboard.waitForExistence(timeout: 20), "dashboard did not appear")
       | `- error: dashboard did not appear
     8 | XCTAssertEqual(rows, 7)
  ✗ check.swift:8:1: error: XCTAssertEqual failed: Int(9) != Int(7)
```

Every failure names the line that recorded it, so you can go straight there
instead of guessing which of five assertions was the one that fired.

## Things that will bite you

**Wait for the thing, never sleep.** `waitForExistence(timeout:)` polls; a sleep
either wastes time or is flaky, usually both. And when a wait can fail in a known
way, say so — this is the single highest-value habit:

```swift
if !dashboard.waitForExistence(timeout: 20, orFailure: app.staticTexts["Invalid password"]) {
    XCTFail(app.staticTexts["Invalid password"].exists ? "login rejected" : "dashboard never came")
}
```

Racing the screen you want against the error the app shows turns a 20-second
timeout into a sub-second answer with a real reason.

**Assert the context, not just the controls.** A script that drives the right
buttons in the wrong project passes happily — it verified *how*, never *where*.
Check the thing that identifies the context (the folder, the account, the
document) before acting on it, and prove the check works by running it once
against the wrong one. A check that has never failed is not yet a check.

**Element counts are device-dependent.** The same list reported 9 rows on iPhone
and 12 on iPad, because SwiftUI only materializes what fits. Assert on *specific*
elements, not on `.count`, unless the count is the thing under test.

**One layout does not imply the other.** A `NavigationSplitView` is a push stack
on iPhone and two columns on iPad, so the same tap sequence lands somewhere else.
Run the same script against both — that is what catches it:

```bash
loupe script check.swift --target "sim:iPhone 17 Pro"
loupe script check.swift --target "sim:iPad Pro 11-inch (M5)"
```

Write the flow so it copes: `if app.buttons["Tasks"].exists { app.buttons["Tasks"].tap() }`
pops back on iPhone and is a harmless no-op on iPad.

**Say which app, on a simulator.** `sim:booted` names the *device*; the bundle id
names the app. Pass the target to the runner and the bundle id in the script.

**Name the device when more than one is booted.** `sim:booted` refuses to guess
rather than picking silently — running an iPhone flow against an iPad looks like
a bug in the app, not a mistargeted command.

**Secrets come from the environment.** Write `env("APP_PASSWORD")` in a script or
`{{APP_PASSWORD}}` in a CLI argument. Never put a real credential in a file you
are about to commit, and never type one into an app you do not own.

**Electron apps look empty until asked.** Chromium keeps its accessibility tree
switched off until an assistive client requests it, so Claude, VS Code, Discord
and friends first report as anonymous nested groups. Loupe turns it on and waits;
if a describe still comes back contentless, run it once more before concluding
the app has no accessibility.

**A simulator's first run pays a build.** Loupe builds and installs a small UI-test
runner the first time it drives a device (~40 s, then cached). Later runs start in
a few seconds. A black window appearing briefly on the device is that runner; it
has no UI of its own and backgrounds as soon as it drives your app.

## Writing a value is not the same as the app accepting it

`setValue` writes through the accessibility API, and for most apps that is the
end of it. When it matters — anything you would not want silently wrong — check
the **outcome**, not the field you wrote.

The field is the weak witness. An app can update the control, run its formatter
over what you wrote, hold the value through a focus change, and still never
commit it. One real accounting app did all four, so every signal available from
the field said success while the app kept its original value and saved that
instead. `setValue` therefore reports what the field now reads and stops short
of claiming the app took it.

What to do about it:

- **Prefer values the app supplies itself.** Selecting the right row first, so a
  form opens pre-filled, is more reliable than typing the same value in — there
  is nothing to be silently rejected. Write only the fields you must.
- **Verify against something the app produced**: a confirmation, a total that
  moved, a list row that appeared. Those come from its model. The field does not.
- **Typing is not automatically safer.** Into a formatted field it can be worse:
  typing `5555` into one currency field yielded `$ 55,00`, because the formatter
  consumed the keystrokes its own way.
- If a control ignores `press` entirely, use `cursorClick` — a real click, for
  controls that expose no working accessibility action.

## When something will not resolve

A name that does not match exactly is an error, not a near miss to act on. The
error lists what *does* contain it, so the next step is usually obvious:

```
Error: de — nothing matches that exactly. 2 element(s) contain it:
    window "Chain" → g2n0
    button "Delete Account" #del → g2n18
  Name one exactly, or use its handle.
```

Loupe will not guess, because a guess that presses something reads exactly like
success — `press "de"` activating Delete Account is worse than any error. If the
listing does not make the right target obvious, fall back to looking:

In order, and each is quick:

1. `loupe describe` — is the element there at all, under a different name? Check
   for a `… not expanded` line first: the thing you want may simply be one
   `--at` away rather than missing.
2. `loupe capture --annotate --out shot.png` — numbered boxes over every
   actionable element, so you can see what Loupe thinks is addressable.
3. `loupe doctor` — permissions (Accessibility, Screen Recording) and setup.

If the element is genuinely missing from the tree, stop reaching for coordinates
and add an `accessibilityIdentifier` in the app. It makes the app testable *and*
usable by people who need VoiceOver, which is the better fix either way.

## Worked example

`Examples/TaskDemo` is a small universal SwiftUI app, and
`Examples/TaskDemo/flow.swift` is the check an agent would write after building
it — filter the list, open a task, toggle it, add one through a sheet, and take
before/after proof. It runs unchanged on both iPhone and iPad.
