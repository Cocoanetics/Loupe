import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LoupeCore

extension MacDriver {
    // MARK: - Window management

    /// What to do to the resolved window.
    ///
    /// These live outside ``UIAction`` because they are macOS-only, and outside
    /// AppleScript because Apple Events need per-application consent that
    /// *blocks on a user prompt* — fatal for anything running unattended, and
    /// exactly the dependency this driver exists to avoid. Every one of these is
    /// a plain accessibility action on the window's own controls.
    public enum WindowCommand: String, Sendable, CaseIterable {
        case close
        case minimize
        case deminimize
        /// Reorder to the front of its app without activating the app.
        case raise
    }

    @discardableResult
    public func window(_ command: WindowCommand) async throws -> ActionResult {
        try await prepare()
        guard let windowElement else {
            throw LoupeError.targetNotFound("no window resolved for \(targetDescription)")
        }

        switch command {
            case .minimize, .deminimize:
                let value = command == .minimize
                let status = AXUIElementSetAttributeValue(
                    windowElement, kAXMinimizedAttribute as CFString, value as CFTypeRef)
                guard status == .success else {
                    throw LoupeError.failed(
                        "could not \(command.rawValue) the window (AX error \(status.rawValue))")
                }
                return ActionResult(message: "\(command.rawValue)d \(targetDescription)")

            case .raise:
                // AXRaise reorders the window but does NOT activate the app, which is
                // the whole point: bring a window forward without stealing focus.
                let status = AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
                guard status == .success else {
                    throw LoupeError.failed("could not raise the window (AX error \(status.rawValue))")
                }
                return ActionResult(message: "raised \(targetDescription) (app not activated)")

            case .close:
                guard let button = Self.windowButton(windowElement, subrole: kAXCloseButtonSubrole) else {
                    throw LoupeError.unsupported(
                        "this window has no close button — a panel or sheet may not be closable this way")
                }
                if AXAPI.bool(button, kAXEnabledAttribute) == false {
                    throw LoupeError.failed("the window's close button is disabled")
                }
                let status = AXUIElementPerformAction(button, kAXPressAction as CFString)
                guard status == .success else {
                    throw LoupeError.failed("could not close the window (AX error \(status.rawValue))")
                }
                return ActionResult(message: "closed \(targetDescription)")
        }
    }

    /// A window's own control button, found by accessibility subrole rather than
    /// by position or label — the buttons are unlabeled, and their order differs
    /// between apps and localizations.
    private static func windowButton(_ window: AXUIElement, subrole: String) -> AXUIElement? {
        AXAPI.children(window).first { AXAPI.string($0, kAXSubroleAttribute) == subrole }
    }

    // MARK: - Window resolution

    func resolveWindow() throws {
        guard let applicationElement, let application = runningApplication else {
            throw LoupeError.targetNotFound(appLocator)
        }
        let windows = AXAPI.windows(applicationElement)
        let name = application.localizedName ?? appLocator
        guard !windows.isEmpty else {
            throw Self.noWindowsError(for: application, named: name)
        }
        // Title match first: it survives a transient panel stealing index 0.
        if let windowTitle {
            let hit = try Self.firstWindow(in: windows, matching: windowTitle, appNamed: name)
            resolvedWindowIndex = hit.offset
            windowElement = hit.element
            return
        }

        let index = windowIndex ?? 0
        guard index >= 0, index < windows.count else {
            let titles = windows.enumerated()
                .map { "#\($0.offset) '\(AXAPI.string($0.element, kAXTitleAttribute) ?? "untitled")'" }
                .joined(separator: ", ")
            throw LoupeError.targetNotFound(
                "\(name) has no window #\(index) — it has \(windows.count): \(titles)")
        }
        resolvedWindowIndex = index
        windowElement = windows[index]
    }

    /// Match the identifier as well as the title: a window's title often
    /// tracks the current screen ("Queue", then "Jobs"), while its
    /// AXIdentifier stays put — so `#main` keeps working across navigation
    /// where `#Health Dashboard` would stop resolving after one click.
    private static func firstWindow(
        in windows: [AXUIElement], matching windowTitle: String, appNamed name: String
    ) throws -> (offset: Int, element: AXUIElement) {
        let needle = windowTitle.lowercased()
        guard
            let hit = windows.enumerated().first(where: {
                let title = (AXAPI.string($0.element, kAXTitleAttribute) ?? "").lowercased()
                let identifier = (AXAPI.string($0.element, kAXIdentifierAttribute) ?? "").lowercased()
                return title.contains(needle) || identifier.contains(needle)
            })
        else {
            let titles = windows.enumerated()
                .map { window in
                    let title = AXAPI.string(window.element, kAXTitleAttribute) ?? "untitled"
                    let identifier = AXAPI.string(window.element, kAXIdentifierAttribute)
                        .map { " id:\($0)" } ?? ""
                    return "#\(window.offset) '\(title)'\(identifier)"
                }
                .joined(separator: ", ")
            throw LoupeError.targetNotFound(
                "\(name) has no window whose title or identifier contains '\(windowTitle)' — "
                    + "it has: \(titles)")
        }
        return hit
    }

    /// Accessibility only lists windows on the *current* Space, so an app whose
    /// window is on another desktop or in full screen looks like an app with no
    /// windows at all. The window server knows better, so ask it and say which
    /// case this is — the two need completely different responses.
    private static func noWindowsError(for application: NSRunningApplication, named name: String)
        -> LoupeError {
        let elsewhere = windowTitlesFromWindowServer(pid: application.processIdentifier)
        if !elsewhere.isEmpty {
            return LoupeError.targetNotFound(
                "\(name) has \(elsewhere.count) window(s) — \(elsewhere.joined(separator: ", ")) — "
                    + "but none on the current Space, and accessibility cannot see across Spaces. "
                    + "This is usually a full-screen window or another desktop. Switch to that Space, "
                    + "or take the window out of full screen, and retry.")
        }
        return LoupeError.targetNotFound(
            "\(name) (pid \(application.processIdentifier)) has no accessibility windows. It may "
                + "have none open, or it may not expose the accessibility API at all.")
    }

    /// Window titles the window server reports for a process, including windows
    /// accessibility cannot see because they are on another Space.
    private static func windowTitlesFromWindowServer(pid: pid_t) -> [String] {
        guard
            let windows = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [] }
        return windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                (window[kCGWindowLayer as String] as? Int) == 0,
                let title = window[kCGWindowName as String] as? String, !title.isEmpty
            else { return nil }
            return "'\(title)'"
        }
    }
}
