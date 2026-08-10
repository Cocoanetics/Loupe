import ApplicationServices
import Foundation
import LoupeCore

extension MacDriver {
    // MARK: - Describe

    /// Cap on how much tree one `describe` may materialize. A runaway hierarchy
    /// (a big outline view, a table with thousands of rows) would otherwise cost
    /// minutes of accessibility IPC and produce a result no agent can read.
    private static let nodeBudget = 5000
    /// Values longer than this are truncated: a text area can hold a whole
    /// document, and dumping it into a tree listing helps nobody.
    private static let valueLimit = 400

    /// Walk the accessibility tree of the window, plus the application's menu
    /// bar.
    ///
    /// The menu bar is included because menus are how most Mac apps expose their
    /// behavior, and `AXPress` on a menu item works on a background app. Menu
    /// items are reported with `enabled: false` when the app's own menu
    /// validation has disabled them — which for a background app is most of
    /// them, since validation keys off a key window that a background app does
    /// not have.
    public func describe(_ options: DescribeOptions) async throws -> [UINode] {
        try requireResolved()
        // A locked screen strips window *contents* from the accessibility tree while
        // leaving the application element and its menu bar, so the result looks like
        // a healthy tree for an app that renders nothing. That reads as an app bug
        // and costs a long detour; say what is actually going on.
        if isScreenLocked() {
            throw LoupeError.failed(
                """
                cannot read the element tree while the screen is locked — macOS leaves the \
                application and its menu bar visible but removes window contents, so any tree \
                returned here would be misleadingly empty.
                  Actions (press, setValue, launch) still work; only reading window contents \
                and capturing do not.
                  Unlock the Mac and retry, or use a sim: or web: target.
                """)
        }
        try ensureResolved()

        // A Chromium shell builds its accessibility tree only after something
        // asks. The switch is thrown when the app is resolved, but building is
        // asynchronous, so the first read can still land before the tree exists.
        //
        // Polled rather than slept on a fixed delay: a fixed wait is wrong in
        // both directions — too long for the common case, and too short for a
        // large app, where it would hand back an empty tree and leave the caller
        // concluding the app has no accessibility at all. That is the whole
        // failure this exists to prevent, so it must not be reintroduced by an
        // arbitrary constant.
        var roots = walkTree(options)
        if !hasContent(roots), !hasWokenChromium {
            hasWokenChromium = true
            // Already set when the app was resolved; set again in case the app
            // was replaced or relaunched since.
            enableManualAccessibility()
            let deadline = Date().addingTimeInterval(Self.chromiumWakeTimeout)
            while !hasContent(roots), Date() < deadline {
                try await Task.sleep(for: .milliseconds(150))
                roots = walkTree(options)
            }
        }
        return roots
    }

    /// Longest to wait for a Chromium tree to appear. Generous because the cost
    /// is only paid by an app that genuinely has nothing addressable yet, and
    /// the alternative — giving up early — is the misleading answer.
    static let chromiumWakeTimeout: TimeInterval = 5

    /// Whether a tree contains anything a caller could address, as opposed to
    /// window chrome and anonymous layout containers.
    private func hasContent(_ roots: [UINode]) -> Bool {
        roots.flatMap { $0.flattened() }.contains { node in
            guard node.role != "window" else { return false }
            if !node.actions.isEmpty { return true }
            return !(node.label?.isEmpty ?? true) || !(node.identifier?.isEmpty ?? true)
        }
    }

    private func walkTree(_ options: DescribeOptions) -> [UINode] {
        nodeIndex.removeAll()

        var state = WalkState(budget: Self.nodeBudget, visited: [])
        var roots: [UINode] = []

        if let window = windowElement {
            roots += walk(
                window, identity: .root(windowRootID), depth: 0, options: options, state: &state)
        }
        // A menu bar needs window → menu → item, so there is no point starting one
        // at all under three levels of depth.
        if options.maxDepth >= 3, let application = applicationElement,
            let menuBar = AXAPI.element(application, kAXMenuBarAttribute) {
            // Menus are wide and repetitive; let them use at most half the budget so
            // a deep window tree is never starved by the File menu.
            let allowance = min(state.budget, Self.nodeBudget / 2)
            var menuState = WalkState(budget: allowance, visited: state.visited)
            roots += walk(
                menuBar, identity: .root(menuRootID), depth: 0, options: options, state: &menuState)
            state.visited = menuState.visited
            state.budget -= (allowance - menuState.budget)
        }

        if let filter = options.filter, !filter.isEmpty {
            roots = roots.compactMap { prune($0, matching: filter) }
        }
        return roots
    }

    private enum NodeIdentity {
        case root(String)
        case child(parent: String, index: Int)
    }

    /// How much of the walk is left, carried down the recursion.
    ///
    /// One value rather than two `inout` parameters, so the menu-bar walk can be
    /// given its own budget while still sharing the cycle guard.
    private struct WalkState {
        var budget: Int
        /// Cycle guard: AX hierarchies are trees by convention, not by guarantee,
        /// and one parent/child loop would hang the walk forever.
        var visited: Set<AXKey>
    }

    /// Returns an array, not an optional node, so an uninteresting element can
    /// splice its children into its parent instead of hiding them.
    private func walk(
        _ element: AXUIElement,
        identity: NodeIdentity,
        depth: Int,
        options: DescribeOptions,
        state: inout WalkState
    ) -> [UINode] {
        guard state.budget > 0 else { return [] }
        guard state.visited.insert(AXKey(element)).inserted else { return [] }
        state.budget -= 1

        let axRole = AXAPI.string(element, kAXRoleAttribute) ?? kAXUnknownRole
        let subrole = AXAPI.string(element, kAXSubroleAttribute)
        let role = RoleMap.normalize(axRole)

        let id: String
        let isRoot: Bool
        switch identity {
            case .root(let rootID):
                id = rootID
                isRoot = true
            case .child(let parent, let index):
                // Built from the *raw* child index, not the filtered one, so the id
                // stays a re-walkable path even when interestingOnly drops nodes.
                id = "\(parent)/\(RoleMap.idTag(for: role))\(index)"
                isRoot = false
        }
        nodeIndex[id] = element

        let described = attributes(of: element, axRole: axRole)

        var children: [UINode] = []
        if depth < options.maxDepth {
            for (index, child) in AXAPI.children(element).enumerated() {
                if state.budget <= 0 { break }
                children += walk(
                    child, identity: .child(parent: id, index: index), depth: depth + 1,
                    options: options, state: &state)
            }
        }

        if !isRoot, options.interestingOnly, !described.isInteresting { return children }

        return [
            UINode(
                id: id,
                role: role,
                rawRole: subrole.map { "\(axRole)/\($0)" } ?? axRole,
                label: described.label,
                value: described.value,
                identifier: described.identifier,
                frame: AXAPI.frame(element),
                enabled: AXAPI.bool(element, kAXEnabledAttribute) ?? true,
                focused: AXAPI.bool(element, kAXFocusedAttribute) ?? false,
                actions: described.actions,
                children: children)
        ]
    }

    /// What an element says about itself, read in one pass.
    private struct Attributes {
        let label: String?
        let value: String?
        let identifier: String?
        let actions: [String]

        /// An element with no name, no value and nothing to do carries no
        /// information of its own, and `interestingOnly` splices it away.
        var isInteresting: Bool {
            label != nil || value != nil || identifier != nil || !actions.isEmpty
        }
    }

    private func attributes(of element: AXUIElement, axRole: String) -> Attributes {
        let title = AXAPI.string(element, kAXTitleAttribute)
        let describedBy = AXAPI.string(element, kAXDescriptionAttribute)
        let rawValue = AXAPI.scalarDescription(element, kAXValueAttribute)
        let value = rawValue.map(Self.truncate)
        // A static text's whole content lives in AXValue, so fall back to it —
        // otherwise every label in the tree would come back nameless.
        //
        // AXRoleDescription is the last resort, and only when it says something the
        // role does not: window controls ("full screen button", "minimize button")
        // carry their only name there, and reporting them as unlabelled sends the
        // caller off to coordinates for a control that could simply be named. It is
        // skipped when it merely repeats the role, which would label every button in
        // the tree "button".
        let roleDescription = AXAPI.string(element, kAXRoleDescriptionAttribute)
        let specificRoleDescription: String? = {
            guard let roleDescription, !roleDescription.isEmpty else { return nil }
            let plain = axRole.replacingOccurrences(of: "AX", with: "").lowercased()
            return roleDescription.lowercased() == plain ? nil : roleDescription
        }()

        return Attributes(
            label: title ?? describedBy ?? value ?? specificRoleDescription,
            value: value,
            identifier: AXAPI.string(element, kAXIdentifierAttribute),
            actions: AXAPI.actions(element))
    }

    /// Keep matching nodes *and* their ancestors, so the result still shows where
    /// in the window a match lives.
    private func prune(_ node: UINode, matching needle: String) -> UINode? {
        let kept = node.children.compactMap { prune($0, matching: needle) }
        guard node.matches(needle) || !kept.isEmpty else { return nil }
        var copy = node
        copy.children = kept
        return copy
    }

    static func truncate(_ text: String) -> String {
        guard text.count > valueLimit else { return text }
        return String(text.prefix(valueLimit)) + "… (+\(text.count - valueLimit) more characters)"
    }
}
