import AppKit
import ApplicationServices
import Foundation
import LoupeCore

extension MacDriver {
    // MARK: - Element resolution

    /// Map a caller's handle to a live element.
    ///
    /// Three chances, cheapest first: the cache from the last describe, then the
    /// id read as a path (which survives a stale cache, because ids are built
    /// from raw child indices), then a full re-describe through
    /// ``UIDriver/resolve(_:options:)`` so that human descriptions like "Save"
    /// work too.
    func resolveElement(_ needle: String) async throws -> (id: String, element: AXUIElement) {
        try ensureResolved()
        if let cached = nodeIndex[needle] { return (needle, cached) }
        if let walked = element(atPath: needle) {
            nodeIndex[needle] = walked
            return (needle, walked)
        }
        let node = try await resolve(needle)
        guard let element = nodeIndex[node.id] else { throw LoupeError.nodeNotFound(needle) }
        return (node.id, element)
    }

    /// Re-walk an id like `w0/g2/b5` through raw child indices.
    private func element(atPath path: String) -> AXUIElement? {
        let segments = path.split(separator: "/")
        guard let first = segments.first else { return nil }
        var current: AXUIElement
        if first == windowRootID, let window = windowElement {
            current = window
        } else if first == menuRootID, let application = applicationElement,
            let menuBar = AXAPI.element(application, kAXMenuBarAttribute) {
            current = menuBar
        } else {
            return nil
        }
        for segment in segments.dropFirst() {
            guard let index = Int(segment.drop(while: { $0.isLetter })) else { return nil }
            let children = AXAPI.children(current)
            guard index >= 0, index < children.count else { return nil }
            current = children[index]
        }
        return current
    }

    /// A short human name for an element, for messages that have to be
    /// actionable when they fail.
    func label(of element: AXUIElement, fallback: String) -> String {
        let role = AXAPI.string(element, kAXRoleAttribute) ?? "element"
        // AXRoleDescription last: it is localized prose ("minimize button"), which
        // is the only name a window control has, but a real title beats it.
        let name =
            AXAPI.string(element, kAXTitleAttribute) ?? AXAPI.string(element, kAXDescriptionAttribute)
            ?? AXAPI.string(element, kAXIdentifierAttribute)
            ?? AXAPI.scalarDescription(element, kAXValueAttribute)
            ?? AXAPI.string(element, kAXRoleDescriptionAttribute)
        guard let name else { return "\(role) \(fallback)" }
        return "\(role) '\(Self.truncate(name))'"
    }

    // MARK: - Target resolution

    func ensureResolved() throws {
        if let application = runningApplication, !application.isTerminated,
            let window = windowElement, AXAPI.string(window, kAXRoleAttribute) != nil {
            return
        }
        try ensureTrusted()
        try resolveApplication()
        try resolveWindow()
    }

    /// Never prompts. `AXIsProcessTrustedWithOptions(prompt: true)` would put a
    /// system dialog on the user's screen — precisely the interruption this
    /// driver exists to avoid — so the remedy is spelled out in the error
    /// instead.
    func ensureTrusted() throws {
        guard AXIsProcessTrusted() else {
            let binary = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "the binary"
            throw LoupeError.permissionDenied(
                "accessibility access is not granted, so no UI tree can be read and no action "
                    + "performed",
                remedy: "System Settings > Privacy & Security > Accessibility, add and enable "
                    + "\(binary) — for a command-line tool that usually means the terminal "
                    + "application hosting it — then run it again.")
        }
    }

    func resolveApplication() throws {
        let matches = findApplication(matching: appLocator)
        guard let application = matches.first else {
            throw LoupeError.targetNotFound(
                "\(appLocator) is not running. Loupe does not launch apps implicitly; use the launch "
                    + "action if that is what you want. Running applications: \(runningAppSummary())")
        }
        if matches.count > 1 {
            // Ambiguity is a correctness problem, not a warning: acting on the wrong
            // app is indistinguishable from acting on nothing.
            let names = matches.compactMap { $0.localizedName }.joined(separator: ", ")
            throw LoupeError.targetNotFound(
                "'\(appLocator)' matches \(matches.count) running applications (\(names)) — use a "
                    + "bundle id or pid:N to disambiguate")
        }
        runningApplication = application
        let element = AXUIElementCreateApplication(application.processIdentifier)
        // Without a timeout a hung app would hang the walk with it; 2s is long
        // enough for a busy app and short enough to report.
        AXUIElementSetMessagingTimeout(element, 2.0)
        applicationElement = element
    }

    private func runningAppSummary() -> String {
        let names = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
            .sorted()
        return names.prefix(20).joined(separator: ", ")
            + (names.count > 20 ? " (+\(names.count - 20) more)" : "")
    }

    /// What the driver actually resolved to, for messages and capture metadata —
    /// as opposed to ``targetDescription``, which only echoes what was asked for.
    var resolvedDescription: String {
        guard let application = runningApplication else { return targetDescription }
        let name =
            application.localizedName ?? application.bundleIdentifier
            ?? "pid \(application.processIdentifier)"
        let title = windowElement.flatMap { AXAPI.string($0, kAXTitleAttribute) }
        return "mac:\(name)#\(resolvedWindowIndex)"
            + (title.map { " '\($0)'" } ?? "")
            + " (pid \(application.processIdentifier))"
    }
}
