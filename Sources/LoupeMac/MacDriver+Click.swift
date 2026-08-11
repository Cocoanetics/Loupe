import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LoupeCore

extension MacDriver {
    // MARK: - Clicking

    /// Press whatever accessibility finds at a point, rather than moving a mouse
    /// there.
    ///
    /// A synthetic mouse event posted to a background process is discarded by
    /// AppKit before `mouseDown:` runs, so the point is used as a *hit test* and
    /// the element under it is pressed. `viaCursor` opts into the real thing.
    func click(x rawX: Double, y rawY: Double, space: CoordinateSpace, viaCursor: Bool)
        throws -> ActionResult {
        guard let application = applicationElement, let window = windowElement else {
            throw LoupeError.targetNotFound(appLocator)
        }
        let point = try screenPoint(x: rawX, y: rawY, space: space, window: window)
        let x = point.x
        let y = point.y

        if viaCursor {
            return try cursorClick(x: x, y: y)
        }
        try requirePoint(x: x, y: y, inside: window)
        guard let hit = AXAPI.elementAt(application, x: x, y: y) else {
            throw LoupeError.nodeNotFound(
                String(format: "no accessibility element at screen point (%.0f, %.0f)", x, y))
        }
        let name = label(of: hit, fallback: "element at (\(Int(x)), \(Int(y)))")

        if AXAPI.bool(hit, kAXEnabledAttribute) == false {
            throw LoupeError.failed("\(name) is disabled — pressing it would do nothing")
        }
        guard AXAPI.actions(hit).contains(kAXPressAction) else {
            return try selectAt(hit, name: name, x: x, y: y)
        }
        let error = AXAPI.perform(hit, kAXPressAction)
        guard error == .success else {
            throw LoupeError.failed("AXPress on \(name) failed: \(AXAPI.describe(error))")
        }
        return ActionResult(
            message: String(format: "pressed %@ found at screen point (%.0f, %.0f)", name, x, y))
    }

    /// Convert a point in `space` to global screen points.
    ///
    /// Every space is anchored on the window's own frame, so a coordinate read off
    /// a screenshot maps back to the same place regardless of Retina scaling or
    /// how much the image was shrunk on its way to a model.
    private func screenPoint(x: Double, y: Double, space: CoordinateSpace, window: AXUIElement)
        throws -> (x: Double, y: Double) {
        guard let frame = AXAPI.frame(window) else {
            throw LoupeError.failed("could not read the window's frame, so coordinates cannot be mapped")
        }
        // Read the real display's scale rather than assuming 2: a window dragged to
        // a non-Retina monitor has a scale of 1, and the difference is a click at
        // double the intended position.
        let scale = WindowCapture.backingScale(forWindowAt: frame) ?? 2.0
        return space.toScreenPoint(x: x, y: y, windowFrame: frame, backingScale: scale)
    }

    /// A point outside the window would hit-test into some other app's UI, so it
    /// is refused rather than pressed.
    private func requirePoint(x: Double, y: Double, inside window: AXUIElement) throws {
        guard let frame = AXAPI.frame(window) else { return }
        guard x >= frame.x, x <= frame.x + frame.width,
            y >= frame.y, y <= frame.y + frame.height
        else {
            throw LoupeError.failed(
                String(
                    format:
                        "point (%.0f, %.0f) is outside the target window, whose screen frame is "
                        + "x=%.0f y=%.0f w=%.0f h=%.0f. Coordinates default to WINDOW points — "
                        + "measured from the window's top-left, not the screen's — so a frame read "
                        + "from `describe` needs the window origin subtracted, or pass it unchanged "
                        + "as `screen:x,y`. The point shown above is the screen point yours "
                        + "resolved to.",
                    x, y, frame.x, frame.y, frame.width, frame.height))
        }
    }

    /// Selection covers SwiftUI rows; beyond that there is genuinely nothing
    /// accessibility can do, and the honest answer is a real click.
    private func selectAt(_ hit: AXUIElement, name: String, x: Double, y: Double) throws
        -> ActionResult {
        if let row = Self.selectableRow(hit) {
            let status = AXUIElementSetAttributeValue(
                row, kAXSelectedAttribute as CFString, true as CFTypeRef)
            if status == .success, AXAPI.bool(row, kAXSelectedAttribute) == true {
                return ActionResult(
                    message: String(
                        format: "selected %@ at screen point (%.0f, %.0f) — it offers no AXPress",
                        name, x, y))
            }
        }
        throw LoupeError.unsupported(
            "the element at (\(Int(x)), \(Int(y))) — \(name) — advertises no AXPress, and a "
                + "CGEvent mouse click posted to a background process is discarded by AppKit "
                + "before mouseDown: runs. Use `cursorclick` for a real click — it briefly "
                + "activates the app and moves the pointer, then puts both back, so it is the "
                + "one action here that the user can see.")
    }

    // MARK: - Cursor click

    /// A real mouse click through the HID stream, for UI that accessibility cannot
    /// reach at all — canvas views, custom-drawn controls, apps with no AX support.
    ///
    /// This is the one thing in Loupe the user can see, so it is opt-in and never a
    /// silent fallback.
    ///
    /// It deliberately does **not** try to activate the app first. macOS ignores
    /// activation requests from a background process — `NSRunningApplication
    /// .activate()` returns true and `AXFrontmost` returns success while nothing
    /// happens — so pre-activating cannot be made reliable from a CLI. It is also
    /// unnecessary: clicking a visible window focuses it, exactly as a user's click
    /// would.
    ///
    /// What it does insist on is that the target window is genuinely the topmost
    /// one under the point. Without that check a click aimed at an occluded window
    /// lands on whatever is covering it — which is the user's own app, doing
    /// something nobody asked for.
    private func cursorClick(x: Double, y: Double) throws -> ActionResult {
        guard let application = runningApplication, let window = windowElement else {
            throw LoupeError.targetNotFound(appLocator)
        }
        let name = application.localizedName ?? appLocator

        guard let frame = AXAPI.frame(window),
            x >= frame.x, x <= frame.x + frame.width,
            y >= frame.y, y <= frame.y + frame.height
        else {
            throw LoupeError.failed(
                String(
                    format: "point (%.0f, %.0f) is outside the target window", x, y))
        }
        try requireTopmost(application, name: name, x: x, y: y)

        let previousCursor = NSEvent.mouseLocation
        // The pointer is the user's; put it back wherever the click lands.
        defer {
            CGWarpMouseCursorPosition(
                CGPoint(
                    x: previousCursor.x,
                    y: (NSScreen.screens.first?.frame.maxY ?? 0) - previousCursor.y))
        }

        let point = CGPoint(x: x, y: y)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard
                let event = CGEvent(
                    mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
                    mouseButton: .left)
            else { throw LoupeError.failed("could not synthesize a mouse event") }
            event.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.03)
        }

        return ActionResult(
            message: String(
                format:
                    "clicked for real at screen point (%.0f, %.0f) on %@. The pointer moved and was put "
                    + "back; the click will have brought %@ forward, exactly as a user's click would. "
                    + "This is the one action here the user can see.",
                x, y, name, name))
    }

    /// Refuse the click unless the target app owns the window a real cursor would
    /// land on.
    private func requireTopmost(
        _ application: NSRunningApplication, name: String, x: Double, y: Double
    ) throws {
        switch Self.topmostWindowOwner(at: CGPoint(x: x, y: y)) {
            case .none:
                throw LoupeError.failed(
                    String(
                        format:
                            "nothing is on screen at (%.0f, %.0f) — the target window may be minimized, "
                            + "hidden, or on another Space. A real click can only reach a visible window.",
                        x, y))
            case .some(let owner) where owner != application.processIdentifier:
                let blocker =
                    NSRunningApplication(processIdentifier: owner)?.localizedName ?? "pid \(owner)"
                throw LoupeError.failed(
                    String(
                        format:
                            "refusing to click at (%.0f, %.0f): the topmost window there belongs to %@, "
                            + "not %@. A real click goes to whatever is visible, so this would have hit "
                            + "the wrong app. Raise the target first (`loupe window raise`), or move the "
                            + "covering window.",
                        x, y, blocker, name))
            default:
                break
        }
    }

    /// pid owning the frontmost on-screen window under a screen point.
    ///
    /// `CGWindowListCopyWindowInfo` returns on-screen windows front-to-back, so the
    /// first hit is what a real click would land on.
    private static func topmostWindowOwner(at point: CGPoint) -> pid_t? {
        guard
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for window in windows {
            // Only normal application windows (layer 0) can occlude a click. The Dock
            // owns a full-screen window at layer 20 and the menu bar sits higher
            // still; counting either would make every click look blocked.
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                let bounds = window[kCGWindowBounds as String] as? [String: Any],
                let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                rect.contains(point),
                let owner = window[kCGWindowOwnerPID as String] as? pid_t
            else { continue }
            if rect.height < 2 || rect.width < 2 { continue }
            return owner
        }
        return nil
    }
}
