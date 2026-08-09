// A login flow written in the XCUITest API.
//
// Run it against a live target:
//
//     APP_PASSWORD=… loupe script Examples/login.swift --screenshots ./proof
//
// The same file compiles unchanged inside a UI-test target, where
// `import XCUIAutomation` resolves to Apple's framework instead of Loupe's.
import XCUIAutomation

let app = XCUIApplication(target: "web:https://example.com/signin")
app.launch()

let dashboard = app.staticTexts["Dashboard"]
let rejected = app.staticTexts["Invalid password"]

// Retry, because a first attempt can lose a race with the page finishing its
// load. Recovering like this only became possible once errors raised inside a
// bridge became catchable — before, a missed element ended the run.
var signedIn = false
for attempt in 1...3 {
    do {
        app.textFields["username"].typeText("admin")
        app.secureTextFields["password"].typeText(env("APP_PASSWORD"))
        app.buttons["Sign In"].tap()
    } catch {
        print("attempt \(attempt) could not complete the form: \(error)")
        app.launch()
        continue
    }

    // Race the screen you want against the app's own error, so a wrong password
    // fails in the time the server takes to say no rather than burning the
    // timeout.
    if dashboard.waitForExistence(timeout: 20, orFailure: rejected) {
        signedIn = true
        break
    }
    if rejected.exists {
        XCTFail("login rejected: \(rejected.label)")
        break
    }
    print("attempt \(attempt): dashboard never appeared, retrying")
    app.launch()
}

// An expectation records and lets the run continue, so everything below still
// executes and the failures are reported together at the end.
XCTAssertTrue(signedIn, "never reached the dashboard")

// Wait for the content to finish loading, not merely for the element to exist.
let status = app.staticTexts["status"]
XCTAssertTrue(status.waitUntil(labelContains: "Ready", timeout: 15), "status never became Ready")

app.screenshot().attach(named: "after-login")
print("logged in, \(app.cells.count) rows on screen")
