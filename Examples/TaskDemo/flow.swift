// The flow an agent would write after implementing TaskDemo, to check its own
// work. Runs unchanged on iPhone and iPad, which present this app very
// differently — a push stack versus a two-column split.
//
//   loupe script Examples/TaskDemo/flow.swift --target sim:booted
//   loupe script Examples/TaskDemo/flow.swift --target "sim:iPad Pro 11-inch (M5)"
//
// The bundle id says which app; --target says which device.
import XCUIAutomation

let app = XCUIApplication(bundleIdentifier: "com.cocoanetics.loupe.examples.taskdemo")
app.launch()

// 1. The list arrived, with the seeded tasks.
XCTAssertTrue(app.buttons["task-1"].waitForExistence(timeout: 20), "task list never appeared")
print("tasks visible:", app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-")).count)

// 2. Filtering is a segmented control; picking "Done" should leave only the
//    every-fourth-task ones the store seeds as complete.
app.buttons["Done"].tap()
let doneCount = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "task-")).count
print("done tasks:", doneCount)
XCTAssertEqual(doneCount, 3, "expected 3 seeded done tasks")

app.buttons["All"].tap()
XCTAssertTrue(app.buttons["task-1"].waitForExistence(timeout: 10))

// 3. Open a task and toggle it. On iPad the detail is already on screen; on
//    iPhone this pushes. The same two lines cover both.
app.buttons["task-1"].tap()
XCTAssertTrue(app.buttons["toggle-done"].waitForExistence(timeout: 10), "detail never appeared")
print("status before:", app.staticTexts["status"].label)
app.buttons["toggle-done"].tap()
XCTAssertTrue(app.staticTexts["Done"].waitForExistence(timeout: 10), "status never became Done")

// 4. Add a task through the sheet.
app.captureBefore(named: "taskdemo-add")
if app.buttons["Tasks"].exists { app.buttons["Tasks"].tap() }   // iPhone: pop back to the list
XCTAssertTrue(app.buttons["add-task"].waitForExistence(timeout: 10))
app.buttons["add-task"].tap()
XCTAssertTrue(app.textFields["new-title"].waitForExistence(timeout: 10), "add sheet never appeared")
app.textFields["new-title"].typeText("Written by Loupe")
app.buttons["save-task"].tap()
XCTAssertTrue(app.buttons["Written by Loupe"].waitForExistence(timeout: 10), "new task never appeared")

let proof = app.captureAfter(named: "taskdemo-add")
print(proof.summary)
print("proof:", proof.path)
