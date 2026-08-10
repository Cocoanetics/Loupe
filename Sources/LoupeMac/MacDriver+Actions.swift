import ApplicationServices
import CoreGraphics
import Foundation
import LoupeCore

extension MacDriver {
    // MARK: - Perform

    public func perform(_ action: UIAction) async throws -> ActionResult {
        try requireResolvedUnlessLaunching(action)
        switch action {
            case .press(let node):
                return try await press(node)
            case .setValue(let node, let value):
                return try await setValue(node, to: value)
            case .click(let x, let y, let space, let viaCursor):
                return try click(x: x, y: y, space: space, viaCursor: viaCursor)
            case .type(let text):
                return try await type(text)
            case .key(let combination):
                return try key(combination)
            case .scrollTo(let needle):
                return try await scrollTo(needle)
            case .scroll(let dx, let dy):
                return try scroll(dx: dx, dy: dy)
            default:
                return try await performProcessAction(action)
        }
    }

    /// `.launch` is the one verb that legitimately runs against a target that
    /// does not exist yet; everything else needs the app resolved.
    private func requireResolvedUnlessLaunching(_ action: UIAction) throws {
        switch action {
            case .launch: break
            default: try requireResolved()
        }
    }

    /// The verbs that act on the application or the session rather than on an
    /// element inside the window.
    private func performProcessAction(_ action: UIAction) async throws -> ActionResult {
        switch action {
            case .navigate(let url):
                return try await navigate(url)
            case .launch(let locator):
                return try await launch(locator)
            case .terminate(let locator):
                return try await terminate(locator)
            case .settle(let timeout):
                return try await settle(timeout: timeout)
            case .waitFor:
                // Handled above the driver, in Loupe.perform(_:on:), because it is just
                // polling `describe` and one implementation serves every surface.
                throw LoupeError.unsupported(
                    "waitFor is handled by LoupeKit, not by a driver directly — call Loupe.act(...)")
            case .evaluate:
                throw LoupeError.unsupported(
                    "evaluating script is web-only — there is no scripting bridge here. Use a web: "
                        + "target for JavaScript, or drive this app with press/setValue/key.")
            default:
                // Unreachable: ``perform(_:)`` handles every element-targeting verb
                // itself and only forwards what is left.
                throw LoupeError.unsupported("\(action) is not an application-level action")
        }
    }

    // MARK: - Press

    private func press(_ needle: String) async throws -> ActionResult {
        let (id, resolved) = try await resolveElement(needle)

        // In list and sidebar UIs the thing carrying the label is a static text
        // *inside* the row, and the row is what is actually pressable. Matching by
        // label therefore lands one or two levels too deep almost every time, so
        // climb to the nearest ancestor that can be pressed rather than making the
        // caller work out the parent's opaque id.
        let (element, climbed) = Self.pressable(from: resolved)

        // SwiftUI `List` rows expose no AXPress at all — only AXShowDefaultUI — so
        // pressing is simply not how they are activated. Selection is: set
        // AXSelected on the row and the app's selection binding fires exactly as if
        // the user had clicked it. Without this, every SwiftUI sidebar is
        // undrivable, which is most modern Mac apps.
        if !AXAPI.actions(element).contains(kAXPressAction),
            let row = Self.selectableRow(resolved) {
            return try select(row, named: label(of: resolved, fallback: id), payload: id)
        }
        let name =
            climbed > 0
            ? "\(label(of: resolved, fallback: id)) (via its \(climbed == 1 ? "parent" : "ancestor"))"
            : label(of: resolved, fallback: id)

        // TRAP: `AXUIElementPerformAction` on a *disabled* element returns
        // kAXErrorSuccess and does nothing at all. The return code carries no
        // information here, so the enabled state has to be read first. This bites
        // hardest on menu items: menu validation keys off the key window, a
        // background app has none, and so most of its menu items are disabled.
        if AXAPI.bool(element, kAXEnabledAttribute) == false {
            throw LoupeError.failed(
                "\(name) is disabled — AXPress would report success and do nothing. "
                    + "If this is a menu item, the app is in the background and has no key window, so "
                    + "its menu validation disables the item; drive the underlying control directly, "
                    + "or bring the app forward yourself if a menu is the only route.")
        }

        let actions = AXAPI.actions(element)
        guard actions.contains(kAXPressAction) else {
            throw LoupeError.unsupported(
                "\(name) does not advertise AXPress. It offers: "
                    + "\(actions.isEmpty ? "no actions at all" : actions.joined(separator: ", ")). "
                    + "Pick one of those, or act on a parent or child element instead.")
        }

        let error = AXAPI.perform(element, kAXPressAction)
        guard error == .success else {
            throw LoupeError.failed("AXPress on \(name) failed: \(AXAPI.describe(error))")
        }
        return ActionResult(message: "pressed \(name)", payload: id)
    }

    /// The nearest element that advertises `AXPress`, and how many levels up it
    /// was found. Answers `(start, 0)` when nothing within four levels can be
    /// pressed, so the caller reports the element the user actually named.
    private static func pressable(from start: AXUIElement) -> (element: AXUIElement, climbed: Int) {
        guard !AXAPI.actions(start).contains(kAXPressAction) else { return (start, 0) }
        var candidate: AXUIElement? = start
        var climbed = 0
        while climbed < 4, let current = candidate {
            guard let next = AXAPI.element(current, kAXParentAttribute) else { break }
            climbed += 1
            if AXAPI.actions(next).contains(kAXPressAction) { return (next, climbed) }
            candidate = next
        }
        return (start, 0)
    }

    /// Activate a row by selecting it, for the lists that offer no `AXPress`.
    private func select(_ row: AXUIElement, named name: String, payload id: String) throws
        -> ActionResult {
        let status = AXUIElementSetAttributeValue(
            row, kAXSelectedAttribute as CFString, true as CFTypeRef)
        guard status == .success else {
            throw LoupeError.failed("could not select \(name) (AX error \(status.rawValue))")
        }
        // Read back: AX accepts this write on elements that then ignore it, and
        // a selection that silently did not happen is the worst outcome — the
        // caller screenshots the previous screen believing it navigated.
        guard AXAPI.bool(row, kAXSelectedAttribute) == true else {
            throw LoupeError.failed(
                "\(name) accepted a selection but did not become "
                    + "selected. Try pressing a child element, or drive the list with arrow keys.")
        }
        return ActionResult(
            message: "selected \(name) — its row offers no AXPress "
                + "(SwiftUI lists do not), so it was activated by setting AXSelected",
            payload: id)
    }

    /// Nearest **row** from `start` upward whose selection can be set.
    ///
    /// The role check is load-bearing. A static text inside a row often reports
    /// `AXSelected` as settable and then ignores the write — success returned,
    /// nothing selected. Only a cell or row actually moves the app's selection, so
    /// anything else is skipped rather than trusted.
    static func selectableRow(_ start: AXUIElement, limit: Int = 5) -> AXUIElement? {
        let rowRoles: Set<String> = ["AXCell", "AXRow", "AXOutlineRow"]
        var current: AXUIElement? = start
        var steps = 0
        while let element = current, steps <= limit {
            if let role = AXAPI.string(element, kAXRoleAttribute), rowRoles.contains(role) {
                var settable = DarwinBoolean(false)
                AXUIElementIsAttributeSettable(element, kAXSelectedAttribute as CFString, &settable)
                if settable.boolValue { return element }
            }
            current = AXAPI.element(element, kAXParentAttribute)
            steps += 1
        }
        return nil
    }

    /// Longest to wait for a field to reflect a write. Short, because this is
    /// only ever a UI framework committing state, not real work.
    private static let valueSettleTimeout: TimeInterval = 1.5

    /// The field's value once it has stopped being the old one.
    ///
    /// Returns as soon as it sees the value that was asked for, so the common
    /// case costs one extra read; otherwise as soon as it sees *any* change, so a
    /// reformatting field is not mistaken for a rejecting one; and gives up at
    /// the timeout, which is what a genuinely rejected write looks like.
    private func settledValue(
        of element: AXUIElement, changedFrom before: String, wanted: String
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(Self.valueSettleTimeout)
        var latest = AXAPI.scalarDescription(element, kAXValueAttribute) ?? ""
        while latest != wanted, latest == before, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            latest = AXAPI.scalarDescription(element, kAXValueAttribute) ?? ""
        }
        return latest
    }

    // MARK: - Set value

    private func setValue(_ needle: String, to value: String) async throws -> ActionResult {
        let (id, element) = try await resolveElement(needle)
        let name = label(of: element, fallback: id)

        guard AXAPI.isSettable(element, kAXValueAttribute) else {
            throw LoupeError.unsupported(
                "\(name) does not allow its AXValue to be set. Try press for a control, or focus the "
                    + "element and use type for a field that only accepts keystrokes.")
        }
        // What it read before, so the check can look for a *change* rather than
        // for an exact match.
        let before = AXAPI.scalarDescription(element, kAXValueAttribute) ?? ""

        let error = AXAPI.set(element, kAXValueAttribute, value as CFTypeRef)
        guard error == .success else {
            throw LoupeError.failed("setting AXValue on \(name) failed: \(AXAPI.describe(error))")
        }

        // Read back: SetValue is the one action that can be verified for free, and
        // a silently rejected write is exactly the lie this package exists to
        // catch. Two things make the naive form of that check lie in the other
        // direction, and both were caught driving a real Electron app.
        //
        // It has to be polled. A React or SwiftUI field commits its state a beat
        // after the write, so an immediate read still returns the old text —
        // reporting failure for a write that had plainly landed.
        //
        // And it has to test for movement, not equality. Plenty of fields
        // legitimately store something other than what was written: trimmed
        // whitespace, a reformatted number, a masked secret, an abbreviated path.
        // What indicates a rejected write is the value not moving at all.
        let readBack = try await settledValue(of: element, changedFrom: before, wanted: value)
        guard readBack != before || value == before else {
            throw LoupeError.failed(
                "AXValue on \(name) was accepted but the element still reads "
                    + "'\(Self.truncate(before))' — the app rejected the value. This is what a "
                    + "secure text field does: macOS will not let accessibility set one, so type "
                    + "into it instead. Capture the window to see what it shows.")
        }
        return ActionResult(
            message: readBack == value
                ? "set value of \(name) to '\(Self.truncate(value))' (verified by read-back)"
                : "set value of \(name); it now reads '\(Self.truncate(readBack))' — the app "
                    + "reformatted what was written",
            payload: id)
    }

    // MARK: - Keyboard

    private func type(_ text: String) async throws -> ActionResult {
        guard let application = runningApplication, let applicationElement else {
            throw LoupeError.targetNotFound(appLocator)
        }
        guard !text.isEmpty else { return ActionResult(message: "nothing to type") }

        try makeFirstResponder()
        guard let focused = AXAPI.element(applicationElement, kAXFocusedUIElementAttribute) else {
            throw LoupeError.failed(
                "no element in \(resolvedDescription) has keyboard focus, so typed characters would "
                    + "go nowhere. Press or focus a text element first — or better, use setValue, "
                    + "which is atomic and needs no focus.")
        }
        let name = label(of: focused, fallback: "the focused element")
        try await MacKeyboard.type(text, to: application.processIdentifier)
        return ActionResult(
            message: "typed \(text.count) character(s) into \(name); key events were delivered to "
                + "pid \(application.processIdentifier), which does not by itself prove the app "
                + "accepted them — capture to confirm")
    }

    private func key(_ combination: String) throws -> ActionResult {
        guard let application = runningApplication else {
            throw LoupeError.targetNotFound(appLocator)
        }
        let (code, flags) = try MacKeyboard.parse(combination)

        // TRAP, measured: a ⌘-shortcut is not delivered to a view, it is resolved
        // against the app's menu — and the same background-app menu validation
        // that disables menu items also swallows their key equivalents. Posting
        // cmd+s to a background TextEdit really does nothing, and the post itself
        // reports no error. Since the menu says up front whether the shortcut can
        // fire, refuse rather than report a hollow success.
        var owner: String?
        if flags.contains(.maskCommand),
            let item = menuItemOwning(keyCode: code, flags: flags) {
            guard item.enabled else {
                throw LoupeError.failed(
                    "\(combination) belongs to the menu item '\(item.title)', which is currently "
                        + "disabled — ⌘-shortcuts are resolved through the menu, so the keystroke would "
                        + "be swallowed with no error. A background app has no key window, which is "
                        + "exactly what menu validation tests. Drive the underlying control with press "
                        + "or setValue, or bring the app forward yourself if the menu is the only route.")
            }
            owner = item.title
        }

        try makeFirstResponder()
        try MacKeyboard.post(key: code, flags: flags, to: application.processIdentifier)
        let attribution = owner.map { " (menu item '\($0)', enabled)" } ?? ""
        return ActionResult(
            message: "posted \(combination) to pid \(application.processIdentifier)\(attribution); "
                + "delivery is not proof the app acted on it — capture to confirm")
    }

    /// Find the menu item that owns a ⌘-shortcut, and whether it can fire.
    ///
    /// `AXMenuItemCmdModifiers` uses the Carbon encoding, where the Command key
    /// is implied and bit 3 means "no Command at all".
    private func menuItemOwning(keyCode: CGKeyCode, flags: CGEventFlags) -> (
        title: String, enabled: Bool
    )? {
        guard let applicationElement,
            let menuBar = AXAPI.element(applicationElement, kAXMenuBarAttribute),
            let character = MacKeyboard.character(for: keyCode)
        else { return nil }

        var expected: AXMenuItemModifiers = []
        if flags.contains(.maskShift) { expected.insert(.shift) }
        if flags.contains(.maskAlternate) { expected.insert(.option) }
        if flags.contains(.maskControl) { expected.insert(.control) }
        if !flags.contains(.maskCommand) { expected.insert(.noCommand) }

        var queue = [menuBar]
        var visited = Set<AXKey>()
        var examined = 0
        while !queue.isEmpty, examined < 3000 {
            let element = queue.removeFirst()
            guard visited.insert(AXKey(element)).inserted else { continue }
            examined += 1
            if let shortcut = AXAPI.string(element, kAXMenuItemCmdCharAttribute),
                shortcut.caseInsensitiveCompare(character) == .orderedSame,
                let modifiers = (AXAPI.copy(element, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?
                    .uint32Value,
                AXMenuItemModifiers(rawValue: modifiers) == expected {
                return (
                    AXAPI.string(element, kAXTitleAttribute) ?? "unnamed",
                    AXAPI.bool(element, kAXEnabledAttribute) ?? true
                )
            }
            queue += AXAPI.children(element)
        }
        return nil
    }

    // MARK: - Focus

    /// Give the app a first responder without activating it.
    ///
    /// Key events posted to a process are dropped unless something inside the
    /// app can receive them, and a background app usually has neither a main
    /// window nor a focused view. Setting `AXMain` (and `AXFocused` as a
    /// fallback) fixes that; verified not to change the frontmost application.
    private func makeFirstResponder() throws {
        guard let window = windowElement, let applicationElement else {
            throw LoupeError.targetNotFound(appLocator)
        }
        AXAPI.set(window, kAXMainAttribute, kCFBooleanTrue)
        if AXAPI.element(applicationElement, kAXFocusedUIElementAttribute) == nil {
            AXAPI.set(window, kAXFocusedAttribute, kCFBooleanTrue)
        }
    }
}
