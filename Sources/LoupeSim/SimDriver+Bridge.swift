import Foundation
import LoupeCore

extension SimDriver {

    /// The bridge for this driver's device, started on first use.
    func bridge() async throws -> Bridge {
        let device = try await ensureReady().device
        if let existing = liveBridge.value { return existing }
        let bridge = try await Bridge.live(for: device.udid)
        // Point it at whatever app is already frontmost, so `describe` works
        // without the caller having to launch anything first — matching how the
        // mac: and web: surfaces behave.
        if let bundleID = await Self.frontmostApp(on: device.udid) {
            _ = try? await bridge.attach(bundleID: bundleID, restart: false)
        }
        liveBridge.value = bridge
        return bridge
    }

    /// The tree of whatever the bridge is pointed at.
    func describeViaBridge(_ options: DescribeOptions) async throws -> [UINode] {
        let bridge = try await bridge()
        if try await bridge.health().isEmpty {
            throw LoupeError.failed(
                "no app is selected on the simulator — run `loupe act sim:… --step launch:<bundle id>` "
                    + "first, or open the app on the device")
        }
        let roots = try await bridge.describe()
        return Self.prune(roots, options: options, depth: 0)
    }

    /// XCUI's tree is faithful but enormous: a SwiftUI screen arrives as twenty
    /// nested `other` containers before anything with a name. Collapsing them
    /// costs nothing — a container with no label, no identifier and no action is
    /// not something a script can address — and it is the difference between a
    /// tree an agent can read and one it cannot.
    static func prune(
        _ nodes: [UINode], options: DescribeOptions, depth: Int
    ) -> [UINode] {
        guard depth < options.maxDepth else { return [] }
        var kept: [UINode] = []
        for node in nodes {
            let children = prune(node.children, options: options, depth: depth + 1)
            if Self.isPassThrough(node) {
                // Hoist the children into the parent's place rather than
                // dropping them with their container.
                kept.append(contentsOf: children)
                continue
            }
            if options.interestingOnly, !Self.isInteresting(node), children.isEmpty {
                continue
            }
            if let needle = options.filter, !Self.subtreeMatches(node, needle) {
                continue
            }
            var copy = node
            copy.children = children
            kept.append(copy)
        }
        return kept
    }

    /// A container that exists only for layout: nothing names it and nothing can
    /// act on it.
    private static func isPassThrough(_ node: UINode) -> Bool {
        guard node.role == "other" || node.role == "group" else { return false }
        let unnamed = (node.label?.isEmpty ?? true) && (node.identifier?.isEmpty ?? true)
        return unnamed && node.actions.isEmpty
    }

    private static func isInteresting(_ node: UINode) -> Bool {
        if !node.actions.isEmpty { return true }
        if !(node.label?.isEmpty ?? true) { return true }
        if !(node.identifier?.isEmpty ?? true) { return true }
        return !(node.value?.isEmpty ?? true)
    }

    private static func subtreeMatches(_ node: UINode, _ needle: String) -> Bool {
        node.flattened().contains { $0.matches(needle) }
    }

    /// Turn a Loupe action into a bridge call.
    ///
    /// Element-addressed actions resolve to a point first: a snapshot cannot be
    /// turned back into the XCUI query that produced it, so the host looks the
    /// element up in the tree it was just given and sends the centre of its
    /// frame. `XCUICoordinate` then delivers a real touch, which is also why
    /// gestures and scrolling work rather than being approximated.
    func performViaBridge(_ action: UIAction) async throws -> ActionResult? {
        let bridge = try await bridge()
        switch action {
            case .press(let node):
                let target = try await locate(node, via: bridge)
                let message = try await bridge.perform(
                    kind: "tap", extra: ["x": target.point.x, "y": target.point.y])
                return ActionResult(message: "\(message) \(describe(target.node))")

            case .setValue(let node, let value):
                let target = try await locate(node, via: bridge)
                let message = try await bridge.perform(
                    kind: "tapAndType",
                    extra: ["x": target.point.x, "y": target.point.y, "text": value])
                return ActionResult(
                    message: "\(message) into \(describe(target.node))",
                    payload: Secrets.redact(value))

            case .type(let text):
                let message = try await bridge.perform(kind: "type", extra: ["text": text])
                return ActionResult(message: message)

            case .key(let key):
                let message = try await bridge.perform(kind: "key", extra: ["key": key])
                return ActionResult(message: "\(message): \(key)")

            case .click(let x, let y, let space, _):
                // Device points are what the bridge speaks, so only normalized
                // coordinates need converting.
                let point = try await devicePoint(x: x, y: y, space: space, via: bridge)
                let message = try await bridge.perform(
                    kind: "tap", extra: ["x": point.x, "y": point.y])
                return ActionResult(message: "\(message) at (\(Int(point.x)), \(Int(point.y)))")

            default:
                return try await performGesture(action, via: bridge)
        }
    }

    private func performGesture(_ action: UIAction, via bridge: Bridge) async throws
        -> ActionResult? {
        switch action {
            case .scroll(let dx, let dy):
                let bounds = try await screenBounds(via: bridge)
                let message = try await bridge.perform(
                    kind: "swipe",
                    extra: [
                        "x": bounds.midX, "y": bounds.midY,
                        // A swipe moves content the way the finger goes, so a
                        // request to scroll down drags upward.
                        "dx": -dx, "dy": -dy
                    ])
                return ActionResult(message: message)

            case .scrollTo(let node):
                // XCUI scrolls implicitly when it taps, so revealing something is
                // a swipe toward it from the middle of the screen.
                let target = try await locate(node, via: bridge)
                let bounds = try await screenBounds(via: bridge)
                if bounds.contains(target.point) {
                    return ActionResult(message: "\(describe(target.node)) is already on screen")
                }
                let message = try await bridge.perform(
                    kind: "swipe",
                    extra: [
                        "x": bounds.midX, "y": bounds.midY,
                        "dx": 0.0, "dy": target.point.y > bounds.midY ? -300.0 : 300.0
                    ])
                return ActionResult(message: "\(message) toward \(describe(target.node))")

            default:
                return nil
        }
    }

    // MARK: - Resolution

    private func locate(
        _ needle: String, via bridge: Bridge
    ) async throws -> (node: UINode, point: CGPoint) {
        let roots = try await bridge.describe()
        let all = roots.flatMap { $0.flattened() }
        guard let node = Self.match(needle, in: all) else {
            throw LoupeError.nodeNotFound(needle)
        }
        guard let frame = node.frame, !frame.isEmpty else {
            throw LoupeError.failed("'\(needle)' has no frame to tap")
        }
        return (node, CGPoint(x: frame.centerX, y: frame.centerY))
    }

    /// Same order the other surfaces use: exact id, identifier, label, then a
    /// substring, preferring something actionable and enabled.
    private static func match(_ needle: String, in nodes: [UINode]) -> UINode? {
        if let hit = nodes.first(where: { $0.id == needle }) { return hit }
        if let hit = nodes.first(where: { $0.identifier == needle }) { return hit }
        if let hit = nodes.first(where: { $0.label == needle }) { return hit }
        let fuzzy = nodes.filter { $0.matches(needle) }
        return fuzzy.first { !$0.actions.isEmpty && $0.enabled }
            ?? fuzzy.first { $0.enabled }
            ?? fuzzy.first
    }

    private func devicePoint(
        x: Double, y: Double, space: CoordinateSpace, via bridge: Bridge
    ) async throws -> CGPoint {
        switch space {
            case .normalized:
                let bounds = try await screenBounds(via: bridge)
                return CGPoint(x: bounds.width * x, y: bounds.height * y)
            case .windowPixels:
                let scale = try await ensureReady().scale
                return CGPoint(x: x / scale, y: y / scale)
            case .windowPoints, .screenPoints:
                // A simulator has one window filling the screen, so these agree.
                return CGPoint(x: x, y: y)
        }
    }

    private func screenBounds(via bridge: Bridge) async throws -> CGRect {
        let roots = try await bridge.describe()
        guard let frame = roots.first?.frame ?? roots.first?.children.first?.frame else {
            throw LoupeError.failed("the bridge reported no screen bounds")
        }
        return CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    private func describe(_ node: UINode) -> String {
        let name = node.label ?? node.identifier ?? node.id
        return "\(node.role) \"\(name)\""
    }

    /// Which app the device is showing, so `describe` works without a launch.
    static func frontmostApp(on udid: String) async -> String? {
        // `simctl listapps` gives what is installed, not what is frontmost;
        // the running process list is the closest public answer.
        guard
            let output = try? await Simctl.run(
                ["spawn", udid, "launchctl", "list"], timeout: 20),
            output.succeeded
        else { return nil }
        for line in output.out.components(separatedBy: "\n") {
            // UIKitApplication:<bundle id>[…] is how launchd names a running app.
            guard let range = line.range(of: "UIKitApplication:") else { continue }
            let rest = line[range.upperBound...]
            let bundleID = rest.prefix { $0 != "[" && $0 != " " }
            if !bundleID.isEmpty, !bundleID.hasPrefix("com.apple.springboard") {
                return String(bundleID)
            }
        }
        return nil
    }
}
