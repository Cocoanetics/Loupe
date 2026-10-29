import AppKit
import ApplicationServices
import Foundation
import LoupeCore

/// What ``MacDriver/closeWindows(_:)`` did to one window.
public enum WindowCloseStatus: String, Sendable {
    case wouldClose = "would close"
    case closed
    /// Closing asked a question and the requested button answered it.
    case answered
    case leftOpen = "left open"
}

extension MacDriver {
    // MARK: - Closing windows in bulk

    /// Which windows `closeWindows(_:)` closes, and what it does about a save sheet.
    public struct CloseRequest: Sendable {
        /// Only windows whose title matches.
        public var title: TitlePattern?
        /// Close every match; without it more than one match is an error.
        public var all: Bool
        /// The button to press when closing puts up a sheet or alert, e.g. "Don’t Save".
        public var answer: String?
        /// Report what would be closed and touch nothing.
        public var dryRun: Bool

        public init(title: TitlePattern? = nil, all: Bool = false, answer: String? = nil, dryRun: Bool = false) {
            self.title = title
            self.all = all
            self.answer = answer
            self.dryRun = dryRun
        }
    }

    /// What became of one window.
    public struct CloseOutcome: Sendable {
        public var status: WindowCloseStatus
        /// `mac:App@id 'title'`.
        public var window: String
        public var detail: String?

        public var message: String {
            "\(status.rawValue) \(window)" + (detail.map { " — \($0)" } ?? "")
        }
    }

    /// Close every window the request selects, one at a time, and answer the
    /// sheet or alert each one puts up.
    ///
    /// Windows are collected before the first close, as elements rather than
    /// indices: closing one shifts every index after it, and a sheet can become
    /// window #0 in the middle of the loop.
    public func closeWindows(_ request: CloseRequest) async throws -> [CloseOutcome] {
        try ensureTrusted()
        try resolveApplication()
        guard let applicationElement else { throw LoupeError.targetNotFound(appLocator) }

        let selected = try selectWindows(request)
        var outcomes: [CloseOutcome] = []
        for window in selected {
            if request.dryRun {
                let closable = Self.windowButton(window, subrole: kAXCloseButtonSubrole) != nil
                outcomes.append(
                    CloseOutcome(
                        status: closable ? .wouldClose : .leftOpen, window: name(of: window),
                        detail: closable ? nil : "it has no close button"))
            } else {
                outcomes.append(await close(window, in: applicationElement, answer: request.answer))
            }
        }
        return outcomes
    }

    /// The windows a request means. An index or id in the target picks exactly
    /// one; otherwise the target's `#title` and `--title` both have to match.
    private func selectWindows(_ request: CloseRequest) throws -> [AXUIElement] {
        guard let applicationElement else { return [] }
        let appName = runningApplication?.localizedName ?? appLocator
        let windows: [AXUIElement]
        if windowID != nil || windowIndex != nil || (request.title == nil && windowTitle == nil && !request.all) {
            try resolveWindow()
            windows = windowElement.map { [$0] } ?? []
        } else {
            windows = AXAPI.windows(applicationElement)
        }
        let selector = windowTitle.map(TitlePattern.init)
        let matches = windows.filter { window in
            let title = AXAPI.string(window, kAXTitleAttribute) ?? ""
            let identifier = AXAPI.string(window, kAXIdentifierAttribute) ?? ""
            let selectorMatches =
                windowID != nil || windowIndex != nil || selector.map {
                    $0.matches(title) || $0.matches(identifier)
                } ?? true
            return selectorMatches && (request.title?.matches(title) ?? true)
        }
        if matches.isEmpty {
            let titles = AXAPI.windows(applicationElement).map(name(of:)).joined(separator: ", ")
            throw LoupeError.targetNotFound(
                "no \(appName) window matches \(targetDescription)"
                    + (request.title.map { " --title '\($0)'" } ?? "")
                    + " — it has: \(titles.isEmpty ? "none on this Space" : titles)")
        }
        if matches.count > 1, !request.all {
            throw LoupeError.failed(
                "\(matches.count) \(appName) windows match: \(matches.map(name(of:)).joined(separator: ", ")) "
                    + "— pass --all to close every one, or narrow --title")
        }
        return matches
    }

    private func close(_ window: AXUIElement, in application: AXUIElement, answer: String?) async
        -> CloseOutcome {
        let name = name(of: window)
        func leftOpen(_ detail: String) -> CloseOutcome {
            CloseOutcome(status: .leftOpen, window: name, detail: detail)
        }
        guard let button = Self.windowButton(window, subrole: kAXCloseButtonSubrole) else {
            return leftOpen("it has no close button")
        }
        if AXAPI.bool(button, kAXEnabledAttribute) == false {
            return leftOpen("its close button is disabled")
        }
        let before = Set(AXAPI.windows(application).map(AXKey.init))
        let status = AXAPI.perform(button, kAXPressAction)
        guard status == .success else {
            return leftOpen("pressing close failed: \(AXAPI.describe(status))")
        }

        var prompt: AXUIElement?
        for _ in 0..<20 {
            if Self.isGone(window, from: application) {
                return CloseOutcome(status: .closed, window: name)
            }
            prompt = Self.prompt(for: window, in: application, existing: before)
            if prompt != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let prompt else { return leftOpen("close was pressed but the window is still open") }

        guard let answer else {
            let labels = Self.buttons(in: prompt).map { "'\($0.label)'" }.joined(separator: ", ")
            return leftOpen("it asks first (\(labels)) — pass --answer with one of those")
        }
        return await respond(to: prompt, of: window, in: application, with: answer, named: name)
    }

    /// Press `answer` in the sheet or alert closing `window` raised, and wait for
    /// the window to go.
    private func respond(
        to prompt: AXUIElement, of window: AXUIElement, in application: AXUIElement, with answer: String,
        named name: String
    ) async -> CloseOutcome {
        func leftOpen(_ detail: String) -> CloseOutcome {
            CloseOutcome(status: .leftOpen, window: name, detail: detail)
        }
        let buttons = Self.buttons(in: prompt)
        let wanted = TitlePattern.normalized(answer)
        guard let choice = buttons.first(where: { TitlePattern.normalized($0.label) == wanted }) else {
            let labels = buttons.map { "'\($0.label)'" }.joined(separator: ", ")
            return leftOpen("it asks first but has no '\(answer)' button — it has \(labels)")
        }
        if AXAPI.bool(choice.element, kAXEnabledAttribute) == false {
            return leftOpen("its '\(choice.label)' button is disabled")
        }
        let pressed = AXAPI.perform(choice.element, kAXPressAction)
        guard pressed == .success else {
            return leftOpen("pressing '\(choice.label)' failed: \(AXAPI.describe(pressed))")
        }
        for _ in 0..<20 {
            if Self.isGone(window, from: application) {
                return CloseOutcome(status: .answered, window: name, detail: "pressed '\(choice.label)'")
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return leftOpen("pressed '\(choice.label)' but the window is still open")
    }

    /// `mac:App@id 'title'` — the id first, because it is what still addresses
    /// the window after others have closed.
    private func name(of window: AXUIElement) -> String {
        let app = runningApplication?.localizedName ?? appLocator
        let identifier = AXAPI.windowNumber(window).map { "@\($0)" } ?? ""
        let title = AXAPI.string(window, kAXTitleAttribute) ?? "untitled"
        return "mac:\(app)\(identifier) '\(title)'"
    }

    private static func isGone(_ window: AXUIElement, from application: AXUIElement) -> Bool {
        AXAPI.string(window, kAXRoleAttribute) == nil
            || !AXAPI.windows(application).contains { CFEqual($0, window) }
    }

    /// The question closing a window raised: a sheet on the window itself, or a
    /// dialog window the app did not have before the close.
    private static func prompt(for window: AXUIElement, in application: AXUIElement, existing: Set<AXKey>)
        -> AXUIElement? {
        if let sheet = AXAPI.children(window).first(where: { AXAPI.string($0, kAXRoleAttribute) == kAXSheetRole }) {
            return sheet
        }
        let dialogs: Set<String> = [kAXDialogSubrole, kAXSystemDialogSubrole]
        return AXAPI.windows(application).first { candidate in
            !existing.contains(AXKey(candidate))
                && (AXAPI.string(candidate, kAXRoleAttribute) == kAXSheetRole
                    || dialogs.contains(AXAPI.string(candidate, kAXSubroleAttribute) ?? ""))
        }
    }

    /// The labelled buttons in a sheet or alert, in tree order.
    private static func buttons(in prompt: AXUIElement, depth: Int = 4) -> [(element: AXUIElement, label: String)] {
        var found: [(element: AXUIElement, label: String)] = []
        for child in AXAPI.children(prompt) {
            if AXAPI.string(child, kAXRoleAttribute) == kAXButtonRole,
                let label = AXAPI.string(child, kAXTitleAttribute) ?? AXAPI.string(child, kAXDescriptionAttribute),
                !label.isEmpty {
                found.append((child, label))
            } else if depth > 0 {
                found += buttons(in: child, depth: depth - 1)
            }
        }
        return found
    }
}
