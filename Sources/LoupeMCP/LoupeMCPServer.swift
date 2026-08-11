import Darwin
import Foundation
import LoupeKit
import LoupeSim
import LoupeXCUI
import SwiftMCP

/// Loupe's verbs as MCP tools, so an agent driven through ACP/acpx gets exactly
/// what the CLI has.
///
/// Two deliberate differences from the CLI: images come back **inline** as
/// content blocks rather than as file paths (an agent cannot open a file it was
/// merely told about), and they are downscaled first — a full 5K capture costs
/// roughly 2,500 image tokens, which makes a screenshot-driven loop expensive
/// fast.
///
/// The tools live in this file because `@MCPServer` only discovers `@MCPTool`
/// members declared in the actor's own body; everything else is in
/// `LoupeMCPServer+Support.swift`.
@MCPServer(name: "loupe", version: "0.1.0")
public actor LoupeMCPServer {

    /// Longest edge, in pixels, of images handed back to the model.
    private let maxEdge: Int

    /// Most recent diff per session, so the numbers can be fetched without
    /// re-rendering the comparison.
    private var lastReports: [String: DiffReport] = [:]

    public init(maxEdge: Int = 1400) {
        self.maxEdge = maxEdge
    }

    /// Stays here rather than in the support file because it reads `maxEdge`,
    /// which `private` scopes to this file.
    private func image(_ png: Data) throws -> MCPImage {
        MCPImage(data: try ImageOps.fit(png, maxEdge: maxEdge), mimeType: "image/png")
    }

    // MARK: - Tools

    /// List everything you can point Loupe at: running Mac apps with their window
    /// titles, and the simulators on this machine. Call this first if you are not
    /// certain how an app or device is named — guessing target names is the most
    /// common cause of a failed call.
    /// - Returns: JSON with `apps`, `simulators`, and whether Accessibility is granted.
    @MCPTool(readOnlyHint: true)
    public func loupe_list_targets() async throws -> String {
        try Self.encode(await Inventory.collect())
    }

    /// Screenshot a target and return the image.
    ///
    /// Targets: `https://example.com` or `web:<url>` for a page in an invisible
    /// web view; `mac:Safari`, `mac:com.apple.Safari`, `mac:pid:123`, `mac:Safari#2`
    /// for a Mac app window; `sim:booted`, `sim:iPhone 17 Pro`, `sim:<udid>` for a
    /// simulator. Mac windows are captured even when occluded, minimized or hidden,
    /// and nothing is brought to the front — the user is never interrupted.
    /// - Parameter target: What to capture.
    /// - Parameter fullPage: Web only — capture the whole scrollable page.
    /// - Parameter settle: Wait for the screen to stop changing first. Default true.
    /// - Parameter region: Optional crop as `x,y,w,h` in target points.
    /// - Parameter viewport: Web viewport as `WxH` CSS pixels, default `1280x900`.
    /// - Parameter scale: Web backing scale, default 2.0.
    /// - Parameter profile: Named persistent web profile, so logins survive between calls.
    @MCPTool(readOnlyHint: true)
    public func loupe_capture(
        target: String,
        fullPage: Bool? = nil,
        settle: Bool? = nil,
        region: String? = nil,
        viewport: String? = nil,
        scale: Double? = nil,
        profile: String? = nil
    ) async throws -> MCPImage {
        let shot = try await Loupe.capture(
            try Target.parse(target),
            options: options(viewport: viewport, scale: scale, profile: profile),
            capture: captureOptions(fullPage: fullPage, settle: settle, region: region))
        return try image(shot.png)
    }

    /// Read a target's element tree: roles, labels, values, identifiers, frames,
    /// and which actions each element supports. Use this instead of guessing at
    /// coordinates from a screenshot — element ids from here are what
    /// `loupe_act` takes, and they encode what is actually clickable.
    /// - Parameter target: What to inspect.
    /// - Parameter depth: Maximum tree depth, default 24.
    /// - Parameter filter: Only return elements whose label, value or id contains this.
    /// - Parameter includeAll: Include layout-only nodes too. Default false, which keeps the tree small.
    /// - Parameter viewport: Web viewport as `WxH`.
    /// - Parameter profile: Named persistent web profile.
    /// - Returns: JSON array of element trees.
    @MCPTool(readOnlyHint: true)
    public func loupe_describe(
        target: String,
        depth: Int? = nil,
        filter: String? = nil,
        includeAll: Bool? = nil,
        viewport: String? = nil,
        profile: String? = nil
    ) async throws -> String {
        let nodes = try await Loupe.describe(
            try Target.parse(target),
            options: options(viewport: viewport, scale: nil, profile: profile),
            describe: DescribeOptions(
                maxDepth: depth ?? 24, interestingOnly: !(includeAll ?? false), filter: filter))
        // A field's value can hold an interpolated secret; scrub before it reaches
        // the transcript.
        return Secrets.redact(try Self.encode(nodes))
    }

    /// Interact with a target, then return a screenshot of the result.
    ///
    /// The steps you supply run in a sensible order (launch, open, press, set,
    /// click, type, key, scroll) against a **single** session, so "open this page
    /// then click that" is one call. This matters: a web target is a fresh page
    /// load per call, so splitting the click and the screenshot across two calls
    /// would throw away the state the click produced.
    ///
    /// Mac apps are driven through the accessibility API — the user's cursor never
    /// moves and the app is never brought forward. Simulators accept only `launch`
    /// and `open`; tapping needs an XCUITest runner Loupe does not have yet, and
    /// you will get a clear error rather than a silent no-op.
    /// - Parameter target: What to act on.
    /// - Parameter press: Element id, identifier or label to activate.
    /// - Parameter setValue: `<element>=<text>`, sets a value directly (full Unicode, no keystrokes). For a
    ///   secret, pass `<element>={{ENV_VAR_NAME}}` — the value is read from the environment on this machine, so
    ///   it never enters your context.
    /// - Parameter click: `x,y` in target points, when there is no element to name.
    /// - Parameter type: Text to type into whatever has focus.
    /// - Parameter key: A key such as `return`, `tab`, `escape`, `down`, or `cmd+s`.
    /// - Parameter scroll: `dx,dy`.
    /// - Parameter open: A URL or deep link to open in the target.
    /// - Parameter launch: An app to launch — bundle id, app name, or `.app` path.
    @MCPTool
    public func loupe_act(
        target: String,
        press: String? = nil,
        setValue: String? = nil,
        click: String? = nil,
        type: String? = nil,
        key: String? = nil,
        scroll: String? = nil,
        open: String? = nil,
        launch: String? = nil,
        viewport: String? = nil,
        profile: String? = nil
    ) async throws -> MCPImage {
        let pending = try ActionRequest(
            press: press, setValue: setValue, click: click, type: type, key: key, scroll: scroll,
            open: open, launch: launch).actions()
        guard !pending.isEmpty else {
            throw LoupeError.failed(
                "no action given — supply at least one of press/setValue/click/type/key/scroll/open/launch")
        }
        let (_, shot) = try await Loupe.act(
            try Target.parse(target),
            actions: pending,
            options: options(viewport: viewport, scale: nil, profile: profile),
            captureAfter: .default)
        guard let shot else { throw LoupeError.failed("actions ran but no screenshot was produced") }
        return try image(shot.png)
    }

    /// Run a whole UI flow written in the XCUITest API, and get back what it
    /// printed plus every expectation that failed, each naming the line it
    /// failed on.
    ///
    /// Reach for this over a chain of `loupe_act` calls when the flow has more
    /// than a couple of steps, when it needs to wait for something, or when you
    /// want to read values back — a script can branch, loop, wait, and print,
    /// and it runs against one session so state carries across steps.
    ///
    /// The script is ordinary Swift written against `XCUIApplication`, and it is
    /// the same source a UI test would contain, so a flow proved here pastes
    /// into a real test unchanged:
    ///
    ///     import XCUIAutomation
    ///
    ///     let app = XCUIApplication(target: "mac:MyApp")
    ///     app.buttons["add-task"].tap()
    ///     XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 10), "never saved")
    ///     print(app.staticTexts["total"].value)
    ///
    /// A failed expectation records and keeps going, so one run reports every
    /// problem rather than dying at the first. Failures come back rendered with
    /// the source line and a caret, so go to the line named in `issues` rather
    /// than re-deriving which step broke.
    /// - Parameter source: The script itself. Supply this or `path`.
    /// - Parameter path: A script file on disk to run instead of `source`.
    /// - Parameter target: What a bare `XCUIApplication()` refers to, e.g. `mac:MyApp`.
    /// - Parameter viewport: Web viewport as `WxH` CSS pixels, default `1280x900`.
    /// - Parameter profile: Named persistent web profile, so logins survive between runs.
    /// - Parameter screenshots: Directory for screenshots the script attaches.
    /// - Parameter timeout: Seconds before the run is abandoned. Default 120.
    /// - Returns: JSON with `status` (passed/skipped/failed), `output`, `issues`,
    ///   `attachments`, and `duration`.
    @MCPTool
    public func loupe_script(
        source: String? = nil,
        path: String? = nil,
        target: String? = nil,
        viewport: String? = nil,
        profile: String? = nil,
        screenshots: String? = nil,
        timeout: Double? = nil
    ) async throws -> String {
        let script = try Self.scriptSource(source: source, path: path)
        let report = await LoupeScript.run(
            ScriptRequest(
                source: script.text,
                fileName: script.name,
                defaultTarget: try target.map { try Target.parse($0) },
                options: options(viewport: viewport, scale: nil, profile: profile),
                attachmentDirectory: Self.directory(screenshots)),
            // A flow that waits on a screen which never appears would otherwise
            // hang the caller indefinitely, and an agent has no console to
            // interrupt from.
            timeout: timeout ?? 120)
        return try Self.encode(report)
    }

    /// Evaluate JavaScript against a web target and return its result as text.
    /// Separate from `loupe_act` because here the returned value is the point.
    /// - Parameter target: A web target.
    /// - Parameter javascript: The expression to evaluate.
    @MCPTool
    public func loupe_eval(
        target: String, javascript: String, viewport: String? = nil, profile: String? = nil
    ) async throws -> String {
        let (results, _) = try await Loupe.act(
            try Target.parse(target),
            actions: [.evaluate(javascript)],
            options: options(viewport: viewport, scale: nil, profile: profile))
        return Secrets.redact(results.first?.payload ?? results.first?.message ?? "")
    }

    /// Record the "before" state of a fix and return what was captured.
    ///
    /// Do this **before** changing any code — that is the entire point, and it
    /// cannot be reconstructed afterwards. The session is stored on disk, so
    /// `loupe_after` can run in a later turn, after a rebuild, or even in a
    /// different agent session.
    /// - Parameter session: A name for this comparison, e.g. the issue number.
    /// - Parameter target: What to capture.
    /// - Parameter open: Optionally navigate/deep-link here first.
    /// - Parameter press: Optionally activate this element first, to reach the affected screen.
    @MCPTool
    public func loupe_before(
        session: String,
        target: String,
        open: String? = nil,
        press: String? = nil,
        fullPage: Bool? = nil,
        region: String? = nil,
        viewport: String? = nil,
        profile: String? = nil
    ) async throws -> MCPImage {
        let (shot, _) = try await Loupe.before(
            session: session,
            target: try Target.parse(target),
            options: options(viewport: viewport, scale: nil, profile: profile),
            capture: captureOptions(fullPage: fullPage, settle: true, region: region),
            actions: try ActionRequest(press: press, open: open).actions())
        return try image(shot.png)
    }

    /// Record the "after" state and return the side-by-side proof image, with the
    /// regions that changed boxed in red. Attach this to the issue or merge
    /// request as evidence the fix works.
    ///
    /// Throws if the two captures are identical: that almost always means the fix
    /// is not in the running build (stale process, forgotten rebuild) rather than
    /// a fix that happens to be invisible. Call `loupe_diff_report` for the
    /// numbers on their own.
    /// - Parameter session: The name used for `loupe_before`.
    /// - Parameter target: Omit to reuse the target recorded with `before`.
    /// - Parameter open: Optionally navigate/deep-link here first.
    /// - Parameter press: Optionally activate this element first.
    @MCPTool
    public func loupe_after(
        session: String,
        target: String? = nil,
        open: String? = nil,
        press: String? = nil,
        fullPage: Bool? = nil,
        region: String? = nil,
        viewport: String? = nil,
        profile: String? = nil
    ) async throws -> MCPImage {
        let outcome = try await Loupe.after(
            session: session,
            target: try target.map { try Target.parse($0) },
            options: options(viewport: viewport, scale: nil, profile: profile),
            capture: captureOptions(fullPage: fullPage, settle: true, region: region),
            actions: try ActionRequest(press: press, open: open).actions())
        guard outcome.report.isDifferent else {
            throw LoupeError.failed(
                "the 'after' capture is pixel-identical to the 'before' one. The fix is almost "
                    + "certainly not in what you just captured — rebuild and relaunch the app, or check "
                    + "you reached the same screen. The image pair is at \(outcome.path.path) if you want to look.")
        }
        self.lastReports[session] = outcome.report
        return try image(outcome.composite)
    }

    /// The numbers behind a comparison: how much changed, the largest per-channel
    /// difference, and the bounding boxes of the changed regions in target points.
    /// - Parameter session: The comparison to report on.
    @MCPTool(readOnlyHint: true)
    public func loupe_diff_report(session: String) async throws -> String {
        guard let report = lastReports[session] else {
            throw LoupeError.failed(
                "no diff recorded for session '\(session)' in this process — run loupe_after first")
        }
        return try Self.encode(report)
    }

    /// Compare two PNG files that already exist and return the side-by-side image.
    /// - Parameter beforePath: Path to the earlier image.
    /// - Parameter afterPath: Path to the later image.
    @MCPTool(readOnlyHint: true)
    public func loupe_compare(beforePath: String, afterPath: String) async throws -> MCPImage {
        let beforeImage = try Data(contentsOf: URL(fileURLWithPath: beforePath))
        let afterImage = try Data(contentsOf: URL(fileURLWithPath: afterPath))
        let report = try ImageOps.diff(before: beforeImage, after: afterImage)
        let composite = try ImageOps.sideBySide(
            before: beforeImage, after: afterImage, report: report, caption: report.summary)
        return try image(composite)
    }

    /// Open a target and keep it alive across calls, addressable afterwards as
    /// `@name`.
    ///
    /// **Only web targets need this.** A Mac app or a simulator already outlives
    /// your calls — `loupe_act` on `mac:Safari` then `loupe_describe` on
    /// `mac:Safari` works with no session at all, because the app itself holds the
    /// state. A web page has no such owner: without a session every call reloads
    /// it, so a login, a scroll position or a half-filled form is gone by the next
    /// call. Open a session whenever you need to look, decide, act and look again
    /// on the web.
    ///
    /// The session exits on its own after 15 idle minutes. Close it when done.
    /// - Parameter target: What to hold open, e.g. a URL.
    /// - Parameter name: What to call it. Later calls use `@name` as their target.
    /// - Parameter viewport: Web viewport as `WxH`.
    /// - Parameter profile: Named persistent web profile, so cookies outlive even the session.
    @MCPTool
    public func loupe_session_open(
        target: String, name: String, viewport: String? = nil, profile: String? = nil
    ) async throws -> String {
        try await openSession(target: target, name: name, viewport: viewport, profile: profile)
    }

    /// List the live sessions you can address as `@name`.
    @MCPTool(readOnlyHint: true)
    public func loupe_session_list() async throws -> String {
        let sessions = LiveSession.list()
        guard !sessions.isEmpty else { return "No open sessions." }
        return try Self.encode(sessions)
    }

    /// Close a live session and free its process.
    /// - Parameter name: The session name, with or without the leading `@`.
    @MCPTool
    public func loupe_session_close(name: String) async throws -> String {
        let clean = name.hasPrefix("@") ? String(name.dropFirst()) : name
        let descriptor = try LiveSession.load(clean)
        kill(descriptor.pid, SIGTERM)
        LiveSession.remove(clean)
        return "Closed @\(clean)."
    }

    /// Freeze a simulator's status bar (clock, battery, signal) so it cannot
    /// cause a false difference between a before and after screenshot. Worth
    /// doing before any simulator comparison — a ticking clock changes pixels on
    /// its own.
    /// - Parameter device: Simulator target, default `booted`.
    /// - Parameter time: Time to display, default `9:41`.
    /// - Parameter clear: Remove the override instead of setting it.
    @MCPTool
    public func loupe_sim_status_bar(
        device: String? = nil, time: String? = nil, clear: Bool? = nil
    ) async throws -> String {
        let driver = SimDriver(deviceLocator: device ?? "booted")
        try await driver.prepare()
        if clear == true {
            return try await driver.clearStatusBar().message
        }
        return try await driver.setStatusBar(
            time: time ?? "9:41", batteryLevel: 100, wifiBars: 3, cellularBars: 4).message
    }

    /// Switch a simulator between light and dark appearance.
    /// - Parameter mode: `light` or `dark`.
    /// - Parameter device: Simulator target, default `booted`.
    @MCPTool
    public func loupe_sim_appearance(mode: String, device: String? = nil) async throws -> String {
        let driver = SimDriver(deviceLocator: device ?? "booted")
        try await driver.prepare()
        return try await driver.setAppearance(mode).message
    }

    /// Check which surfaces are usable and what permission is missing if one is
    /// not. Call this when a capture fails in a way that looks like a
    /// permissions problem — an empty tree or a black image usually is one.
    @MCPTool(readOnlyHint: true)
    public func loupe_doctor() async throws -> String {
        await Diagnostics.run().lines.joined(separator: "\n")
    }
}
