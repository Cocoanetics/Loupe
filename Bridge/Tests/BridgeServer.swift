import Darwin
import Foundation
import XCTest

/// A never-ending UI test that serves the simulator's UI over loopback HTTP.
///
/// Everything else Loupe drives — a Mac app, a web page — can be reached from
/// the host process. A simulator cannot: `simctl` has no notion of an element,
/// and the accessibility that Simulator.app bridges to macOS is flattened, lossy
/// and missing whole containers (a tab bar arrives as a childless group). The
/// only complete view of a running iOS app is XCUITest's, and XCUITest only
/// exists inside a UI-test process.
///
/// So the host builds this bundle once, installs it on the device, and talks to
/// it. Because a UI-test bundle needs no test host, one runner drives every
/// installed app on every booted device.
///
/// Note the test never ends: `executionTimeAllowance` is raised and the loop
/// runs until the host says `/quit` or the deadline passes. Nothing collects a
/// result — there is no xcresult and no failure reporting — which is fine for
/// something that answers over a socket.
final class BridgeServer: XCTestCase {

    /// Raised because the whole point is to outlive a normal test.
    private static let sessionLimit: TimeInterval = 6 * 60 * 60

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testServe() throws {
        let environment = ProcessInfo.processInfo.environment
        let port = environment["LOUPE_BRIDGE_PORT"].flatMap { UInt16($0) } ?? 18110
        // No token means refuse to serve, not serve everything: loopback on a
        // shared machine is not a privacy boundary, and failing open here would
        // hand any local process a way to drive the device.
        let token = environment["LOUPE_BRIDGE_TOKEN"] ?? ""
        try XCTSkipIf(token.isEmpty, "LOUPE_BRIDGE_TOKEN is required")
        executionTimeAllowance = Self.sessionLimit

        let listener = try Listener(port: port)
        NSLog("LOUPE_BRIDGE listening on %d", Int(port))

        let session = AppSession()
        let deadline = Date().addingTimeInterval(Self.sessionLimit)
        while Date() < deadline {
            guard let connection = listener.accept() else { continue }
            defer { connection.close() }
            guard let request = connection.readRequest() else { continue }

            // Loopback is not a privacy boundary on a shared machine, so the
            // host stamps every request with the token it generated.
            if request.header("x-loupe-token") != token {
                connection.send(status: 403, json: ["error": "bad or missing token"])
                continue
            }
            if request.path == "/quit" {
                connection.send(status: 200, json: ["ok": true])
                return
            }
            let response = session.handle(request)
            connection.send(status: response.status, json: response.body)
        }
    }
}

/// Whichever app the host asked for, kept between requests.
@MainActor
private final class AppSession {

    private var app: XCUIApplication?
    private var bundleID: String?

    func handle(_ request: Request) -> (status: Int, body: [String: Any]) {
        do {
            switch request.path {
                case "/health":
                    return (200, ["ok": true, "bundleID": bundleID ?? ""])
                case "/launch":
                    return (200, try launch(request))
                case "/activate":
                    return (200, try activate(request))
                case "/terminate":
                    try current().terminate()
                    return (200, ["ok": true])
                case "/describe":
                    return (200, ["roots": [try Tree.node(of: try current())]])
                case "/act":
                    return (200, try act(request))
                default:
                    return (404, ["error": "unknown path \(request.path)"])
            }
        } catch let error as BridgeError {
            return (400, ["error": error.message])
        } catch {
            return (500, ["error": "\(error)"])
        }
    }

    private func current() throws -> XCUIApplication {
        guard let app else {
            throw BridgeError("no app selected — POST /launch or /activate with a bundleID first")
        }
        return app
    }

    private func launch(_ request: Request) throws -> [String: Any] {
        let identifier = try request.string("bundleID")
        let app = XCUIApplication(bundleIdentifier: identifier)
        if let environment = request.body["environment"] as? [String: String] {
            app.launchEnvironment = environment
        }
        if let arguments = request.body["arguments"] as? [String] {
            app.launchArguments = arguments
        }
        app.launch()
        self.app = app
        self.bundleID = identifier
        let ready = app.wait(for: .runningForeground, timeout: 30)
        return ["ok": ready, "state": app.state.rawValue]
    }

    /// Attach to something already running, without restarting it — the common
    /// case when a script is inspecting a state the user set up.
    private func activate(_ request: Request) throws -> [String: Any] {
        let identifier = try request.string("bundleID")
        let app = XCUIApplication(bundleIdentifier: identifier)
        if app.state == .notRunning { app.launch() } else { app.activate() }
        self.app = app
        self.bundleID = identifier
        return ["ok": app.wait(for: .runningForeground, timeout: 30), "state": app.state.rawValue]
    }

    // MARK: - Acting

    /// Every action is expressed against a point, because a snapshot cannot be
    /// turned back into the query that produced it. The host resolves an element
    /// to a frame from the tree it was just given, and sends the centre of it;
    /// `XCUICoordinate` then delivers a real touch, which is also what makes
    /// gestures and off-screen scrolling work.
    private func act(_ request: Request) throws -> [String: Any] {
        let app = try current()
        let kind = try request.string("kind")
        switch kind {
            case "tap", "press":
                try coordinate(app, request).tap()
                return ["ok": true, "message": "tapped"]
            case "doubleTap":
                try coordinate(app, request).doubleTap()
                return ["ok": true, "message": "double tapped"]
            case "longPress":
                let duration = request.body["duration"] as? Double ?? 1.0
                try coordinate(app, request).press(forDuration: duration)
                return ["ok": true, "message": "pressed for \(duration)s"]
            case "type":
                let text = try request.string("text")
                app.typeText(text)
                return ["ok": true, "message": "typed \(text.count) character(s)"]
            case "tapAndType":
                try coordinate(app, request).tap()
                let text = try request.string("text")
                app.typeText(text)
                return ["ok": true, "message": "typed \(text.count) character(s)"]
            case "swipe":
                return ["ok": true, "message": try swipe(app, request)]
            case "key":
                app.typeText(try Self.keySequence(for: try request.string("key")))
                return ["ok": true, "message": "sent key"]
            case "button":
                try press(hardware: try request.string("button"))
                return ["ok": true, "message": "pressed device button"]
            default:
                throw BridgeError("unknown action '\(kind)'")
        }
    }

    private func coordinate(_ app: XCUIApplication, _ request: Request) throws -> XCUICoordinate {
        let x = try request.double("x")
        let y = try request.double("y")
        return app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: x, dy: y))
    }

    private func swipe(_ app: XCUIApplication, _ request: Request) throws -> String {
        let start = try coordinate(app, request)
        let dx = request.body["dx"] as? Double ?? 0
        let dy = request.body["dy"] as? Double ?? 0
        let end = start.withOffset(CGVector(dx: dx, dy: dy))
        start.press(forDuration: 0.05, thenDragTo: end)
        return "swiped by (\(dx), \(dy))"
    }

    private func press(hardware button: String) throws {
        switch button.lowercased() {
            case "home": XCUIDevice.shared.press(.home)
            default: throw BridgeError("unknown device button '\(button)' — only home is available")
        }
    }

    /// XCUI has no key API on iOS; the named keys map onto the characters
    /// `typeText` understands.
    private static func keySequence(for key: String) throws -> String {
        switch key.lowercased() {
            case "return", "enter": return "\n"
            case "tab": return "\t"
            case "delete", "backspace": return XCUIKeyboardKey.delete.rawValue
            case "escape": return XCUIKeyboardKey.escape.rawValue
            case "space": return " "
            default:
                guard key.count == 1 else {
                    throw BridgeError("unknown key '\(key)'")
                }
                return key
        }
    }
}

struct BridgeError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
