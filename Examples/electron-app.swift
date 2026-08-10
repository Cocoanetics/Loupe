// Driving an Electron app on macOS through the XCUITest API.
//
//   loupe script Examples/electron-app.swift
//
// Electron is worth its own example because a Chromium shell keeps its
// accessibility tree switched off until an assistive client asks. Loupe turns it
// on and waits, so from a script it reads like any other app — but the roles
// come from the web content rather than AppKit, which is what this exercises.
import XCUIAutomation

let app = XCUIApplication(target: "mac:Claude")

// The mode switcher and the new-conversation button live in the sidebar.
XCTAssertTrue(app.buttons["Code"].waitForExistence(timeout: 15), "sidebar never appeared")
print("mode buttons:", app.buttons["Home"].exists, app.buttons["Code"].exists)

app.buttons["New"].tap()

// The composer carries a local/cloud button, a folder pop-up and the prompt.
let prompt = app.textFields["Prompt"]
XCTAssertTrue(prompt.waitForExistence(timeout: 15), "the composer never appeared")
print("local button:", app.buttons["Local"].exists)
print("prompt placeholder:", prompt.value)

// Check what this conversation is scoped to, before typing anything into it.
//
// Without this the script passes against whichever folder happened to be
// selected — it drives the UI correctly and verifies nothing about *where*. A
// check that cannot fail is worse than no check, because it reads as one.
//
// Asserted by label because this app exposes no accessibility identifiers for
// its web content; the only identified elements are AppKit menu items, whose
// identifiers are Objective-C selectors.
let folder = "MissionControl"
XCTAssertTrue(
    app.buttons[folder].exists,
    "expected this conversation to be scoped to \(folder) — check the folder pop-up")
print("folder scope confirmed:", folder)

prompt.setText("Driven from an XCUITest-shaped script, on an Electron app.")

// Send becomes usable once there is something to send. Deliberately not tapped:
// this example proves the path without starting a conversation.
let send = app.buttons["Send"]
XCTAssertTrue(send.waitForExistence(timeout: 10), "no Send button")
print("send enabled after typing:", send.isEnabled)

prompt.setText("")
print("composer cleared")
