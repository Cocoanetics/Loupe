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
        // Bounded: the walk is synchronous accessibility traffic, one IPC round
        // trip per attribute per node, and a window holding a few hundred
        // realized table rows takes long enough to look like a hang. `depth` does
        // bound it — measured 0.3s at depth 1 against >30s unbounded on a window
        // with a few hundred rows — but `filter` does not: it walks everything
        // and then discards, so filtering is the slow way to ask a small question.
        try await Deadline.run(seconds: 30, "reading this window's element tree") { [self] in
            Unchecked(try await describeNow(options))
        }.value
    }

    private func describeNow(_ options: DescribeOptions) async throws -> [UINode] {
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
        // Reported here, where a bad handle can still be told apart from a filter
        // that matched nothing. Left to the caller, an empty result from either
        // cause reads as "no such element" — which sends someone hunting for a
        // stale handle when the handle was fine.
        if let root = options.root, !root.isEmpty, element(atPath: root) == nil {
            throw LoupeError.nodeNotFound(root)
        }
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

        // Re-rooted: open one branch without paying for the tree above it. The
        // handle is walked back through raw child indices, so ids underneath come
        // out byte-identical to the ones a full describe would have printed —
        // which is the whole point, since the caller got this handle from one.
        if let root = options.root, !root.isEmpty {
            guard let element = element(atPath: root) else { return [] }
            roots = walk(element, identity: .root(root), depth: 0, options: options, state: &state)
            // Falls through to the filter below rather than returning here:
            // `--at` and `--filter` are independent, and returning early made the
            // pair mean something different on this surface than on the others.
            return applyFilter(options, to: roots)
        }

        if let window = windowElement {
            roots += walk(
                window, identity: .root(windowRootID), depth: 0, options: options, state: &state)
        }
        if let application = applicationElement,
            let menuBar = AXAPI.element(application, kAXMenuBarAttribute) {
            switch options.scope {
                case .primary:
                    // 73% of a default describe on a real app was the menu bar, and
                    // at depth 3 it was 94% — an agent asking about a window paid
                    // 20k tokens and got the File menu. Named and counted here, one
                    // call away, rather than expanded into the answer.
                    roots.append(collapsedMenuBar(menuBar))
                case .all:
                    // A menu bar needs window → menu → item, so there is no point
                    // starting one at all under three levels of depth.
                    guard options.maxDepth >= 3 else { break }
                    // Menus are wide and repetitive; let them use at most half the
                    // budget so a deep window tree is never starved by the File menu.
                    let allowance = min(state.budget, Self.nodeBudget / 2)
                    var menuState = WalkState(budget: allowance, visited: state.visited)
                    roots += walk(
                        menuBar, identity: .root(menuRootID), depth: 0, options: options,
                        state: &menuState)
                    state.visited = menuState.visited
                    state.budget -= (allowance - menuState.budget)
            }
        }

        return applyFilter(options, to: roots)
    }

    private func applyFilter(_ options: DescribeOptions, to roots: [UINode]) -> [UINode] {
        guard let filter = options.filter, !filter.isEmpty else { return roots }
        return roots.compactMap { prune($0, matching: filter) }
    }

    /// The children of one element, and whatever the walk did not reach.
    ///
    /// Split out from ``walk(_:identity:depth:options:state:)`` so both stay
    /// readable; the two are one operation.
    private func walkChildren(
        of element: AXUIElement, parent: String, depth: (own: Int, children: Int),
        options: DescribeOptions, state: inout WalkState
    ) -> (children: [UINode], elided: Elision?) {
        let raw = AXAPI.children(element)
        guard depth.own < options.maxDepth else {
            return ([], raw.isEmpty ? nil : Elision(children: raw.count, reason: .depth))
        }
        var children: [UINode] = []
        for (index, child) in raw.enumerated() {
            guard state.budget > 0 else {
                return (children, Elision(children: raw.count - index, reason: .budget))
            }
            children += walk(
                child, identity: .child(parent: parent, index: index), depth: depth.children,
                options: options, state: &state)
        }
        return (children, nil)
    }

    /// The menu bar as one line per menu, with each menu's item count.
    ///
    /// Enough to answer "does this app have a Format menu" and to hand back a
    /// handle for the one menu worth opening, without walking 245 nodes to say so.
    private func collapsedMenuBar(_ menuBar: AXUIElement) -> UINode {
        var titles: [UINode] = []
        for (index, item) in AXAPI.children(menuBar).enumerated() {
            let id = "\(menuRootID)/\(RoleMap.idTag(for: "menuitem"))\(index)"
            nodeIndex[id] = item
            // A menu bar item holds one AXMenu; that menu's children are the items.
            let count = AXAPI.children(item).first.map { AXAPI.children($0).count } ?? 0
            titles.append(
                UINode(
                    id: id, role: "menuitem",
                    label: AXAPI.string(item, kAXTitleAttribute),
                    elided: count > 0 ? Elision(children: count, reason: .collapsed) : nil))
        }
        return UINode(id: menuRootID, role: "menu", label: "menu bar", children: titles)
    }

    /// Drop frames that describe no rectangle.
    ///
    /// Menu items report `0 × 0 at (0, 1440)` — off-screen, sizeless, identical
    /// on every item. Carrying that costs a fifth of the payload and tells a
    /// caller nothing it could act on. A zero *width* alone is kept: a vertical
    /// splitter is genuinely 0 × 962.
    static func meaningfulFrame(_ frame: Frame?) -> Frame? {
        guard let frame else { return nil }
        return (frame.width == 0 && frame.height == 0) ? nil : frame
    }

    /// The element's identifier, from whichever attribute its toolkit uses.
    ///
    /// AppKit sets `AXIdentifier`. Chromium does not — it puts the DOM `id` in
    /// `AXDOMIdentifier` instead, so every Electron app looked to Loupe as though
    /// it identified nothing at all.
    ///
    /// Worth reading even though the values are often unhelpful: React generates
    /// ids like `_r_1r_` that change between renders, and seeing one is itself
    /// the useful signal — it says "do not key on this", which is a better answer
    /// than an empty column that could mean either "no id" or "not looked at".
    static func identifier(of element: AXUIElement) -> String? {
        if let native = AXAPI.string(element, kAXIdentifierAttribute), !native.isEmpty {
            return native
        }
        let dom = AXAPI.string(element, "AXDOMIdentifier")
        return (dom?.isEmpty ?? true) ? nil : dom
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

        // Depth is charged only for nodes that will actually be shown. It used to
        // count walk levels, so on a SwiftUI window three levels bought a
        // splitter and two anonymous wrappers — and on the simulator, where
        // twenty nested containers before anything named is normal, a sensible
        // depth returned an empty tree that reads as "this app has no
        // accessibility". Scaffolding the caller never sees should not spend the
        // caller's budget.
        let shown = isRoot || !options.interestingOnly || described.isInteresting
        let childDepth = shown ? depth + 1 : depth

        let (children, elided) = walkChildren(
            of: element, parent: id, depth: (own: depth, children: childDepth),
            options: options, state: &state)

        // A node hiding something is interesting whatever its label says.
        //
        // Without the `elided` clause this splice returned `children`, which at
        // the depth frontier is empty — so an unnamed container deleted itself
        // *and its entire subtree*, leaving nothing behind to say so. That is how
        // `--depth 3` on a settings window reported nine elements while the whole
        // sidebar quietly went missing.
        if !isRoot, options.interestingOnly, !described.isInteresting, elided == nil {
            return children
        }

        return [
            UINode(
                id: id,
                role: role,
                rawRole: subrole.map { "\(axRole)/\($0)" } ?? axRole,
                label: described.label,
                value: described.value,
                identifier: described.identifier,
                frame: Self.meaningfulFrame(AXAPI.frame(element)),
                enabled: AXAPI.bool(element, kAXEnabledAttribute) ?? true,
                focused: AXAPI.bool(element, kAXFocusedAttribute) ?? false,
                actions: described.actions,
                children: children,
                elided: elided)
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
            identifier: Self.identifier(of: element),
            actions: AXAPI.actions(element))
    }

    /// Keep matching nodes *and* their ancestors, so the result still shows where
    /// in the window a match lives.
    private func prune(_ node: UINode, matching needle: String) -> UINode? {
        let kept = node.children.compactMap { prune($0, matching: needle) }
        // `node.elided != nil` keeps a frontier node whose subtree was never
        // walked. Dropping it would report "no match" for something that may sit
        // just below the cap — the same silent false negative this whole change
        // exists to remove, arriving by a different route.
        guard node.matches(needle) || !kept.isEmpty || node.elided != nil else { return nil }
        var copy = node
        copy.children = kept
        return copy
    }

    static func truncate(_ text: String) -> String {
        guard text.count > valueLimit else { return text }
        return String(text.prefix(valueLimit)) + "… (+\(text.count - valueLimit) more characters)"
    }
}
