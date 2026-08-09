import Foundation
import LoupeCore
import WebKit

// Doing things to the page, and the envelope plumbing every verb answers through.

extension WebDriver {

    // MARK: - Act

    public func perform(_ action: UIAction) async throws -> ActionResult {
        try await exclusive {
            try await self.ensureReady()
            guard self.webView != nil else {
                throw LoupeError.failed("the web view went away before the action")
            }
            return try await self.dispatch(action)
        }
    }

    /// Route one action to the verb that implements it.
    ///
    /// Split across two switches rather than one thirteen-case block, but every
    /// case is still spelled out in both, so the compiler keeps checking that a new
    /// `UIAction` is routed deliberately instead of falling into a `default`.
    private func dispatch(_ action: UIAction) async throws -> ActionResult {
        switch action {
            case .press(let node):
                return try await press(node)
            case .setValue(let node, let value):
                return try await setValue(node, to: value)
            case .click(let x, let y, let space, let viaCursor):
                return try await click(x: x, y: y, in: space, viaCursor: viaCursor)
            case .type(let text):
                return try await runAction(WebScripts.type(text: text))
            case .key(let combo):
                return try await sendKey(combo)
            case .scrollTo(let node):
                return try await scrollIntoView(node)
            case .scroll(let dx, let dy):
                return try await scrollBy(dx: dx, dy: dy)
            case .navigate, .evaluate, .settle, .waitFor, .launch, .terminate:
                return try await performPageVerb(action)
        }
    }

    /// The verbs that act on the page as a whole rather than on something in it.
    private func performPageVerb(_ action: UIAction) async throws -> ActionResult {
        switch action {
            case .navigate(let target):
                return try await navigateAction(to: target)

            case .evaluate(let source):
                return try await evaluateUserScript(source)

            case .settle(let timeout):
                return try await settleAction(timeout: timeout)

            case .waitFor:
                // Handled above the driver, in Loupe.perform(_:on:), because it is just
                // polling `describe` and one implementation serves every surface.
                throw LoupeError.unsupported(
                    "waitFor is handled by LoupeKit, not by a driver directly — call Loupe.act(...)")

            case .launch(let what):
                throw LoupeError.unsupported(
                    "launching '\(what)' — a web driver only ever has this one page. Use a mac: target to "
                        + "launch an application, or the navigate action to go somewhere else here.")

            case .terminate(let what):
                throw LoupeError.unsupported(
                    "terminating '\(what)' — call shutdown() to close this web view, or use a mac: target "
                        + "to quit an application.")

            case .press, .setValue, .click, .type, .key, .scrollTo, .scroll:
                throw LoupeError.failed("internal: \(action) should have been handled by dispatch(_:)")
        }
    }

    // MARK: - Verbs

    private func press(_ node: String) async throws -> ActionResult {
        let (handle, note) = try await resolveHandle(node)
        var result = try await runAction(WebScripts.press(handle: handle, generation: generation))
        result.message = [note, result.message].compactMap { $0 }.joined(separator: "; ")
        if let navigated = await absorbNavigation() {
            result.message += "; \(navigated)"
        }
        return result
    }

    private func setValue(_ node: String, to value: String) async throws -> ActionResult {
        let (handle, note) = try await resolveHandle(node)
        var result = try await runAction(WebScripts.setValue(handle: handle, value: value))
        result.message = [note, result.message].compactMap { $0 }.joined(separator: "; ")
        return result
    }

    /// A page has one coordinate system: CSS pixels.
    ///
    /// Normalized coordinates are resolved against the viewport, which is what
    /// makes a click derived from a downscaled screenshot land correctly.
    private func click(x: Double, y: Double, in space: CoordinateSpace, viaCursor: Bool) async throws
        -> ActionResult {
        guard !viaCursor else {
            throw LoupeError.unsupported(
                "cursorclick moves the real mouse, which only means something for an on-screen "
                    + "window; this web view is never ordered on screen. Use click, which "
                    + "dispatches the full pointer sequence into the page.")
        }
        var cssX = x
        var cssY = y
        switch space {
            case .normalized:
                cssX = x * viewport.width
                cssY = y * viewport.height
            case .windowPixels:
                cssX = x / scale
                cssY = y / scale
            case .windowPoints, .screenPoints:
                break
        }
        var result = try await runAction(WebScripts.click(x: cssX, y: cssY))
        if let navigated = await absorbNavigation() {
            result.message += "; \(navigated)"
        }
        return result
    }

    private func sendKey(_ combo: String) async throws -> ActionResult {
        var result = try await runAction(WebScripts.key(combo))
        if let navigated = await absorbNavigation() {
            result.message += "; \(navigated)"
        }
        return result
    }

    private func scrollIntoView(_ node: String) async throws -> ActionResult {
        let result = try await runAction(WebScripts.scrollIntoView(handle: node))
        _ = try? await settlePage(timeout: 1)
        return result
    }

    private func scrollBy(dx: Double, dy: Double) async throws -> ActionResult {
        let result = try await runAction(WebScripts.scroll(dx: dx, dy: dy))
        _ = try? await settlePage(timeout: 1)
        return result
    }

    private func navigateAction(to target: String) async throws -> ActionResult {
        let previous = currentURL
        try await navigate(to: target)
        return ActionResult(
            message: "navigated from \(previous) to \(currentURL)"
                + (navigator?.lastStatusCode.map { $0 >= 400 ? " (HTTP \($0))" : "" } ?? ""),
            payload: currentURL)
    }

    private func settleAction(timeout: Double) async throws -> ActionResult {
        let notes = try await settlePage(timeout: timeout)
        return ActionResult(
            ok: notes.isEmpty,
            message: notes.isEmpty ? "the page stopped changing" : notes.joined(separator: "; "))
    }

    /// If the last action started a navigation, wait it out so the caller's next
    /// capture is of the page they landed on rather than a half-torn-down one.
    private func absorbNavigation() async -> String? {
        guard let webView else { return nil }
        // Give the click's default action a moment to turn into a load.
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard webView.isLoading else {
            if let state = try? await readPageState(), state.url != liveURL.value {
                let previous = liveURL.value
                liveURL.value = state.url
                return "the page moved from \(previous) to \(state.url) without a full load (SPA routing)"
            }
            return nil
        }
        let deadline = Date().addingTimeInterval(navigationTimeout)
        while webView.isLoading, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let previous = liveURL.value
        if let state = try? await readPageState() { liveURL.value = state.url }
        if webView.isLoading {
            return "it started a navigation that is still running after \(Int(navigationTimeout))s"
        }
        return previous == liveURL.value
            ? "it reloaded the page" : "it navigated to \(liveURL.value)"
    }

    // MARK: - Script plumbing

    func runScript(_ source: String) async throws -> ScriptEnvelope {
        guard let webView else { throw LoupeError.failed("the web view is not ready") }
        let json: String
        do {
            json = try await loupeEvaluate(webView, source)
        } catch is UnsupportedJSResultType {
            // Only reachable if a page replaced JSON.stringify; every script here
            // returns a string by construction.
            throw LoupeError.failed(
                "the page's JavaScript environment returned something unexpected — it may have replaced "
                    + "JSON.stringify or another built-in this driver depends on")
        }
        let envelope = try decodeEnvelope(json)
        guard envelope.succeeded else { throw error(from: envelope) }
        return envelope
    }

    private func runAction(_ source: String) async throws -> ActionResult {
        let envelope = try await runScript(source)
        return ActionResult(
            ok: true, message: envelope.message ?? "done", payload: envelope.payload)
    }

    func decodeEnvelope(_ json: String) throws -> ScriptEnvelope {
        guard let data = json.data(using: .utf8) else {
            throw LoupeError.failed("the page returned a result that is not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode(ScriptEnvelope.self, from: data)
        } catch {
            throw LoupeError.failed(
                "could not read the page's answer (\(error)) — raw result: \(json.prefix(400))")
        }
    }

    private func error(from envelope: ScriptEnvelope) -> LoupeError {
        let message = envelope.message ?? "the page rejected the action"
        switch envelope.code {
            case "nodeNotFound": return .nodeNotFound(message)
            case "unsupported": return .unsupported(message)
            case "timeout": return .timeout(message)
            default: return .failed(message)
        }
    }

    /// `evaluate`, with the fallback for values the JS bridge refuses to carry.
    private func evaluateUserScript(_ source: String) async throws -> ActionResult {
        guard let webView else {
            throw LoupeError.failed("the web view went away before the action")
        }
        let label = source.count > 60 ? String(source.prefix(57)) + "…" : source
        do {
            let value = try await loupeEvaluate(webView, source)
            return ActionResult(message: "evaluated \(label)", payload: value)
        } catch is UnsupportedJSResultType {
            // Re-run through callAsyncJavaScript, which can await a Promise and lets
            // us JSON-encode the result inside the page before it crosses the bridge.
            // Only used as a fallback because it needs `eval`, which a strict
            // Content-Security-Policy will block.
            let value = try await loupeCallAsync(
                webView, body: WebScripts.evaluateBody, arguments: ["source": source])
            return ActionResult(
                message: "evaluated \(label) (result serialized in-page; promises awaited)", payload: value)
        }
    }
}
