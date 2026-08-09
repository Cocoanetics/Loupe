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

Anything with a `#` has an accessibility identifier — use that. It survives copy
changes and translation; a visible label does not.

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
loupe script check.swift --target sim:booted
```

A failed expectation **records and keeps going**, so one run reports every problem
it found rather than dying at the first:

```
check.swift FAILED after 2.3s
  ✗ dashboard did not appear
  ✗ XCTAssertEqual failed: Optional(String("2")) != String("7")
```

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

**Element counts are device-dependent.** The same list reported 9 rows on iPhone
and 12 on iPad, because SwiftUI only materializes what fits. Assert on *specific*
elements, not on `.count`, unless the count is the thing under test.

**One layout does not imply the other.** A `NavigationSplitView` is a push stack
on iPhone and two columns on iPad, so the same tap sequence lands somewhere else.
Run the same script against both — that is what catches it:

```bash
loupe script check.swift --target sim:booted
loupe script check.swift --target "sim:iPad Pro 11-inch (M5)"
```

Write the flow so it copes: `if app.buttons["Tasks"].exists { app.buttons["Tasks"].tap() }`
pops back on iPhone and is a harmless no-op on iPad.

**Say which app, on a simulator.** `sim:booted` names the *device*; the bundle id
names the app. Pass the target to the runner and the bundle id in the script.

**Secrets come from the environment.** Write `env("APP_PASSWORD")` in a script or
`{{APP_PASSWORD}}` in a CLI argument. Never put a real credential in a file you
are about to commit, and never type one into an app you do not own.

**A simulator's first run pays a build.** Loupe builds and installs a small UI-test
runner the first time it drives a device (~40 s, then cached). Later runs start in
a few seconds. A black window appearing briefly on the device is that runner; it
has no UI of its own and backgrounds as soon as it drives your app.

## When something will not resolve

In order, and each is quick:

1. `loupe describe` — is the element there at all, under a different name?
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
