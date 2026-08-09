import Foundation
import LoupeKit

extension ElementBox {

    /// `tap()` and `click()` — one verb underneath.
    ///
    /// XCUI splits these by platform, which forces the same flow to be written
    /// twice behind `#if os(…)`. Both spellings are accepted here and both mean
    /// "activate this element", because on an accessibility tree that is the
    /// only thing either one can mean. It also has the property XCUI's version
    /// does not: nothing moves on screen and the app never has to come forward.
    func activate() async throws -> ActionResult {
        let node = try await resolve()
        return try await run(.press(node: node.id))
    }

    /// XCUI types into the element, which implies focusing it first.
    func typeText(_ text: String) async throws -> ActionResult {
        let node = try await resolve()
        if !node.focused {
            // Focus by pressing. Plenty of text fields do not advertise AXPress,
            // so a failure here is expected rather than exceptional.
            _ = try? await run(.press(node: node.id))
        }
        do {
            return try await run(.type(text))
        } catch {
            // Nothing had focus and the field would not take a press. Setting
            // the value directly is the only route left, and it is the right one
            // often enough to be worth trying before giving up — except on
            // secure fields, where macOS refuses it outright.
            let existing = node.value ?? ""
            guard !(node.rawRole ?? "").localizedCaseInsensitiveContains("Secure") else {
                throw LoupeError.failed(
                    "could not type into \(description): it took neither focus nor a value. "
                        + "Secure fields must be focused first — click the field, or press Tab to it.")
            }
            return try await run(.setValue(node: node.id, value: existing + text))
        }
    }

    /// Replace the value outright.
    ///
    /// Not XCUI — there the idiom is select-all then type. Direct assignment is
    /// both faster and more reliable on an accessibility tree, so it is exposed
    /// rather than emulated. macOS refuses it on secure text fields; the error
    /// says so.
    func setText(_ text: String) async throws -> ActionResult {
        let node = try await resolve()
        return try await run(.setValue(node: node.id, value: text))
    }

    /// Ask the app to bring the element into view.
    ///
    /// XCUI scrolls implicitly before interacting and offers no way to say
    /// "just reveal this". Loupe has one, and it beats guessing a scroll
    /// distance — `AXScrollToVisible` is what VoiceOver uses to follow focus,
    /// and it does the right thing inside nested scrollers.
    func scrollToVisible() async throws -> ActionResult {
        let node = try await resolve()
        return try await run(.scrollTo(node: node.id))
    }

    func swipe(dx: Double, dy: Double) async throws -> ActionResult {
        _ = try await resolve()
        return try await run(.scroll(dx: dx, dy: dy))
    }

    /// A real cursor click at the element's centre, for the rare control that
    /// AX will not activate.
    func cursorClick() async throws -> ActionResult {
        let node = try await resolve()
        guard let frame = node.frame, !frame.isEmpty else {
            throw LoupeError.failed("\(description) has no frame to click")
        }
        // Mac frames are global screen points; every other surface reports
        // window-relative ones.
        let space: CoordinateSpace = app.target.surface == .mac ? .screenPoints : .windowPoints
        return try await run(
            .click(x: frame.centerX, y: frame.centerY, space: space, viaCursor: true))
    }

    func screenshot() async throws -> Data {
        let node = try await resolve()
        let driver = try await app.driver()
        let capture = try await driver.capture(CaptureOptions(region: node.frame))
        return capture.png
    }

    private func run(_ action: UIAction) async throws -> ActionResult {
        try await Loupe.perform(action, on: try await app.driver())
    }
}

extension AppBox {

    /// XCUI launches a fresh copy of the app under test. Loupe attaches to
    /// whatever is running, which is a real difference and worth being honest
    /// about: `launch()` here means "make sure it is running and reachable".
    ///
    /// `launchEnvironment` and `launchArguments` only reach a process Loupe
    /// starts itself, so setting them and then attaching to an app that was
    /// already open would silently do nothing. That case throws instead.
    func launch() async throws -> ActionResult {
        let driver = try await driver()
        defer { didLaunch = true }
        switch target.surface {
            case .mac, .sim:
                let result = try await Loupe.perform(.launch(target.locator), on: driver)
                if !launchEnvironment.isEmpty || !launchArguments.isEmpty {
                    guard result.message.localizedCaseInsensitiveContains("launched") else {
                        throw LoupeError.unsupported(
                            "launchEnvironment/launchArguments were set, but \(target.locator) was "
                                + "already running so they had no effect. Quit it first, or drop them.")
                    }
                }
                return result
            case .web:
                // The driver loaded the page when it was prepared; re-navigating
                // makes `launch()` mean the same thing it does elsewhere — start
                // from the top.
                return try await Loupe.perform(.navigate(target.locator), on: driver)
            case .live:
                return ActionResult(message: "attached to session \(target.locator)")
        }
    }

    func terminate() async throws -> ActionResult {
        let driver = try await driver()
        didLaunch = false
        guard target.surface == .mac || target.surface == .sim else {
            throw LoupeError.unsupported(
                "terminate() applies to mac: and sim: targets, not \(target.surface.rawValue):")
        }
        return try await Loupe.perform(.terminate(target.locator), on: driver)
    }

    func open(_ url: String) async throws -> ActionResult {
        try await Loupe.perform(.navigate(url), on: try await driver())
    }

    func typeKey(_ key: String) async throws -> ActionResult {
        try await Loupe.perform(.key(key), on: try await driver())
    }

    func typeText(_ text: String) async throws -> ActionResult {
        try await Loupe.perform(.type(text), on: try await driver())
    }

    func screenshot() async throws -> Data {
        try await driver().capture(.default).png
    }

    /// `app.state` — XCUI reports five states; three of them are distinguishable
    /// here.
    ///
    /// Deliberately does not answer from whether `describe` succeeds: an app
    /// that is running perfectly well but has no window open cannot be
    /// described, and reporting that as `notRunning` would be a lie the script
    /// then acts on. The process table is the authority on whether it is
    /// running; the window list only decides foreground from background.
    func state() async throws -> String {
        guard target.surface == .mac else {
            // A page or a session is reachable exactly when its driver is.
            let reachable = (try? await driver().describe(DescribeOptions(maxDepth: 1))) != nil
            return reachable ? "runningForeground" : "notRunning"
        }
        let inventory = try await Inventory.collect()
        let locator = target.locator
        guard
            let app = inventory.apps.first(where: {
                $0.bundleID?.caseInsensitiveCompare(locator) == .orderedSame
                    || $0.name.caseInsensitiveCompare(locator) == .orderedSame
            })
        else { return "notRunning" }
        return app.windows.isEmpty ? "runningBackground" : "runningForeground"
    }
}
