# Running XCUITest source as a script

A UI flow written once, in the XCUITest API, that runs two ways: compiled into a
UI-test target, or interpreted by
[SwiftScript](https://github.com/Cocoanetics/SwiftScript) against whatever is
already on screen.

```swift
import XCUIAutomation

let app = XCUIApplication(bundleIdentifier: "com.example.MyApp")
app.launch()

app.textFields["username"].typeText("admin")
app.secureTextFields["password"].typeText(env("APP_PASSWORD"))
app.buttons["Sign In"].tap()

XCTAssertTrue(app.staticTexts["Dashboard"].waitForExistence(timeout: 10))
app.screenshot().attach(named: "after-login")
```

```bash
loupe script login.swift --screenshots ./proof
```

No Loupe vocabulary anywhere. That matters for more than taste: it is the API the
app's existing tests are already written in, the API agents already know, and a
flow proven by hand pastes into a test target unchanged.

The job is not really *testing*, though — it is **navigate, then observe**. Drive
the app to the screen where a change shows, then print the values and capture the
proof. Expectations exist so that an unattended run has a meaningful exit status
rather than a screenshot of the wrong screen, not because a script should read
like a test suite.

## Why it is a facade and not Apple's framework

The tempting design is to bridge `XCUIAutomation` directly — no
re-implementation, exact semantics for free. It does not work, and it fails late
enough to be worth recording.

The framework is real and public
(`…/MacOSX.platform/Developer/Library/Frameworks/XCUIAutomation.framework`).
A plain command-line tool links and compiles against it happily, then throws on
the first call:

```
NSInternalInconsistencyException: Device is not configured for UI testing -
use of XCUIApplication is not supported.
```

from inside `-[XCUIApplication commonInitWithApplicationSpecifier:device:]`. XCUI
is a client of `testmanagerd`, and the daemon only grants a session to a process
it launched as a UI-test bundle. The constructor throws before any bridge code
could run, so nothing here can be Apple's implementation.

What it *can* be is a faithful surface over the same idea, backed by the drivers
Loupe already has. In exchange for giving up Apple's implementation you get the
things a test runner cannot do: drive an app that is already running, one nobody
wrote a test target for, or a web page; start in under a second; and never bring
the app forward or move the pointer.

## How one file runs both ways

`Interpreter.registerOnImport(_:module:)` keys on the import name as a **plain
string** — it never resolves a real module. Registering the XCUI surface under
`"XCUIAutomation"` makes the dispatch fall out for free:

| The same file | resolves `import XCUIAutomation` to |
| --- | --- |
| compiled into a UI-test target | Apple's framework |
| run by `loupe script` | this module, backed by Loupe |

Not a shim to opt into, not a conditional import, not a source difference of any
kind. `import XCTest` and `import Testing` are registered too, since roughly half
of real UI-test code drives `XCUIApplication` from Swift Testing rather than
`XCTestCase`.

## What is covered

Ranked by how often each appears in ~4,500 lines of existing UI-test code, since
that is a better guide to what matters than the header order.

| | |
| --- | --- |
| Waiting | `waitForExistence(timeout:)`, `waitForNonExistence(timeout:)` |
| Queries | keyed subscript, `firstMatch`, `element(boundBy:)`, `matching(identifier:)`, `matching(_:)`, `matching(_:identifier:)`, `containing(_:)`, `count`, `allElementsBoundByIndex`, `descendants()`, `children()` |
| Element types | all 82 query providers — `buttons`, `staticTexts`, `textFields`, `secureTextFields`, `collectionViews`, `menuItems`, `outlines`, `popUpButtons`, … |
| Attributes | `exists`, `isEnabled`, `isHittable`, `isSelected`, `label`, `value`, `identifier`, `title`, `elementType`, `frame`, `debugDescription` |
| Actions | `tap()`, `click()`, `typeText(_:)`, `swipeUp/Down/Left/Right()`, `screenshot()` |
| Application | `XCUIApplication(bundleIdentifier:)`, `launch()`, `activate()`, `terminate()`, `state`, `launchEnvironment`, `launchArguments`, `typeKey(_:)` |
| Predicates | `NSPredicate(format:)` over `label`, `identifier`, `value`, `title`, `isEnabled` with `==`, `!=`, `CONTAINS`, `BEGINSWITH`, `ENDSWITH`, `MATCHES`, `[c]`, `AND`, `OR` |
| Expectations | `XCTAssertTrue`, `XCTAssert`, `XCTAssertFalse`, `XCTAssertEqual`, `XCTAssertNotEqual`, `XCTAssertNil`, `XCTAssertNotNil`, `XCTFail`, `XCTUnwrap`, `XCTSkip` — see below |

### Additions

Five things XCUI does not have, each earning its place:

- **`waitForExistence(timeout:orFailure:)`** — race the expected screen against
  the app's own error. Waiting for a dashboard that never arrives burns the whole
  timeout and then reports nothing useful; this returns in the time the app takes
  to reject you. Measured on the sample login: 25 s becomes 0.6 s.
- **`waitUntil(labelContains:timeout:)`** / **`waitUntil(valueContains:timeout:)`** —
  wait for an attribute to *change*, not merely for an element to exist. Every
  surveyed test suite hand-rolls this around `RunLoop.current.run(until:)`.
- **`setText(_:)`** — assign a value rather than select-all-then-type. Faster and
  more reliable through accessibility. macOS refuses it on secure fields, and
  says so.
- **`scrollToVisible()`** (also spelled `reveal()`) — ask the app to reveal the
  element instead of guessing a scroll distance. `AXScrollToVisible` is what
  VoiceOver uses to follow focus, and it works inside nested scrollers.
- **`XCUIApplication(target:)`** and **`env(_:)`** — a web page or a live session
  has no bundle identifier, and a password should come from the environment
  rather than the script. `env` uses the same `{{NAME}}` machinery as the CLI, so
  a secret never reaches a transcript.
- **`captureBefore(named:)` / `captureAfter(named:)`** — the point of the whole
  tool, and the reason a script exists at all. XCUI's `screenshot()` is an
  attachment; this is a comparison. `captureAfter` returns `summary`,
  `isDifferent`, `changedPercent`, `changedRegions` and `path` — the last being a
  side-by-side BEFORE | AFTER image with the changed regions boxed, ready to
  attach to an issue.

```swift
app.captureBefore(named: "totals-fix")
app.buttons["Recalculate"].tap()
XCTAssertTrue(total.waitUntil(labelContains: "1,284", timeout: 5))
let proof = app.captureAfter(named: "totals-fix")
print(proof.summary)   // 0.10% of pixels differ, max channel delta 255, 1 region(s)
print(proof.path)      // ~/.loupe/sessions/totals-fix/compare.png
```

Both use the driver the script already holds open, rather than the one-shot
`loupe before` / `loupe after`, which open their own — on a web target that would
mean a fresh page load, throwing away the state the script just navigated to.

### Divergences

`loupe script --divergences` prints this list; it also lives in
`XCUIModule.divergences` so it cannot drift from the code.

- `tap()` and `click()` are one verb. An accessibility tree has a single notion
  of activation, and this removes the `#if os(…)` twins that split real suites in
  half.
- Activation goes through AX, so the app never comes forward and nothing moves on
  screen.
- `launch()` attaches to a running app rather than starting a fresh one.
  `launchEnvironment` / `launchArguments` only apply when Loupe starts the
  process, and setting them then attaching to something already running throws
  rather than silently ignoring them.
- The keyed subscript also accepts a substring of the label, ranked below every
  exact match. SwiftUI merges a row's texts into one element, so exact-only
  matching fails on the single most common real case. The cost is that a very
  short key can match something XCUI would not — `buttons["n"]` finds "Open". It
  never matches Loupe's internal node handles, though, which would be worse: an
  arbitrary element, silently.
- `rightClick()`, `doubleTap()` and `press(forDuration:)` raise rather than
  no-op — the accessibility layer cannot express them. **Context menus are the
  real gap here.**
- iOS-only queries (`keyboards`, `pickerWheels`, `statusBars`, `touchBars`) say
  why they cannot be satisfied instead of quietly matching nothing.
- `isSelected` reports focus and `isHittable` reports a non-empty enabled frame;
  XCUI computes both from a real hit test.
- `sim:` targets can only launch, terminate, open a URL and capture — `SimDriver`
  has no `describe`, so element queries need the XCUITest runner bridge that does
  not exist yet.

### Interpreter limits

One SwiftScript gap still stops a *verbatim* Swift Testing file from running; two
earlier ones have been closed.

- **`#expect` and `#require` cannot be written**, because the interpreter has no
  evaluation for a macro expansion, and `@Test` / `@Suite` are refused as unknown
  attributes ([#14](https://github.com/Cocoanetics/SwiftScript/issues/14)). This
  is the one gap that still stops a real Swift Testing file from being pasted in
  and run. It is not a spelling problem that could be worked around with a plain
  function: the reason `#expect` is a macro is that it reports the *source text*
  of the expression and the operand values, and a function only ever receives
  `false`.
- ~~`.any` and other leading-dot arguments~~ — closed by
  [#13](https://github.com/Cocoanetics/SwiftScript/pull/13);
  `descendants(matching: .any)` now works verbatim.
- ~~Errors thrown from a bridge cannot be caught~~ — also closed by #13. A script
  can now `do`/`catch` a failed `tap()` and retry, which is what made a
  retry-on-failure flow worth writing as a script in the first place. The waiting
  API still returns `false` rather than throwing, because that is Apple's
  contract: ask the
  failure element's `.exists` to find out *which* condition tripped.

### Expectations follow Swift Testing's model

The spellings above are XCTest's, because they are real API that compiles in a
test target and `#expect` cannot yet be evaluated. What has been taken from
Swift Testing is the part that matters more than the spelling:

- **An expectation records an issue and the run continues.** Only the unwrapping
  form (`XCTUnwrap`, Swift Testing's `#require`) throws.
- A script that ran to completion having recorded issues is a **failed** run, and
  every issue is reported together at the end.

That is XCTest's real behaviour too — `XCTAssertTrue` has never stopped a test —
and for UI automation it is much the better half of the bargain: one run surfaces
every problem, each with the screenshot that was on screen when it happened,
instead of dying on the first and saying nothing about the rest.

```
login.swift FAILED after 2.3s
  ✗ dashboard did not appear
  ✗ XCTAssertEqual failed: Optional(String("2")) != String("7")
  ✗ the sidebar was still showing the previous account
```

Assertions are *not* catchable, deliberately: they are globals rather than bridge
methods, so a `do`/`catch` around a retry loop can recover from a missing element
without silently swallowing a failed expectation.

## Design notes

**Queries are staged, and stay lazy.** A query is a chain of stages — reach some
nodes, narrow them, optionally pick one, then descend into what is left. That is
what makes `app.tables.cells` mean "cells inside tables" rather than "things that
are both a table and a cell"; the flat-filter model that preceded it answered the
intersection, so every chain between two different types came back empty. It also
keeps `cells.element(boundBy: 2).buttons` scoped to row 2.

`app.buttons` resolves nothing until something is read off it, exactly as in
XCUI. That is not a detail to paper over — it is what lets a query survive the
screen changing underneath it, and it maps cleanly onto Loupe, where every action
re-describes the tree anyway. A polling loop therefore describes once per tick,
not once per query.

**Element types are matched against measured roles.** The mapping from XCUI's 82
query providers onto Loupe's fifteen normalized roles was written from the
headers first and was wrong in a dozen places — `<table>` describes as a `group`,
not a `list`; `<select>` as a `list`, not a `button`. The table now reflects what
the drivers actually emit. Native roles are matched as substrings (macOS glues
the subrole on: `AXTextField/AXSecureTextField`) but web roles are matched whole,
because a substring test there made `scrollViews` match a `scrollbar`.

**One driver for the whole script.** The CLI opens a driver per command; a script
holds one open for its lifetime. Per-statement teardown would mean a fresh page
load before every `tap()`, throwing away the login you just performed. `@session`
targets are the exception in the other direction — their shutdown is a no-op, so
a script can attach to a session someone else opened and leave it running.

**Element types are a table, not 240 closures.** 82 query providers across three
receiver types vary only in which roles satisfy them. Every name is registered
even when nothing can back it, so pasting a real test in never dies on an unknown
property: it either works or says precisely why it cannot.
