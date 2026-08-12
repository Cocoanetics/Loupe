import CoreGraphics
import Foundation
import LoupeMac
import LoupeSim
import LoupeWeb

// Re-exported on purpose: every consumer of LoupeKit needs Target, UINode,
// Capture and friends, and making each one import LoupeCore separately is noise.
@_exported import LoupeCore

/// What ``Loupe/after(session:target:options:capture:actions:store:)`` produces:
/// the numbers, the proof image, and where it was written.
public struct ComparisonResult: Sendable {
    public var report: DiffReport
    /// The rendered BEFORE | AFTER image.
    public var composite: Data
    /// Where the composite was saved, for attaching to an issue or MR.
    public var path: URL

    public init(report: DiffReport, composite: Data, path: URL) {
        self.report = report
        self.composite = composite
        self.path = path
    }
}

public enum Loupe {

    /// Knobs that only apply to some surfaces. Kept in one struct so the CLI and
    /// the MCP server pass identical options without each driver's init leaking
    /// into callers.
    public struct Options: Sendable {
        /// Web viewport in CSS pixels.
        public var viewport: CGSize
        /// Backing scale for web rendering (2.0 = Retina).
        public var scale: Double
        /// Named persistent web profile, so logins survive between runs. Nil means
        /// a fresh private session every time.
        public var profile: String?

        public init(
            viewport: CGSize = CGSize(width: 1280, height: 900),
            scale: Double = 2.0,
            profile: String? = nil
        ) {
            self.viewport = viewport
            self.scale = scale
            self.profile = profile
        }

        public static let `default` = Options()
    }

    /// Resolve a target to a driver. The driver is not prepared yet — call
    /// ``UIDriver/prepare()`` (or use ``withDriver(_:options:body:)``).
    @MainActor
    public static func driver(for target: Target, options: Options = .default) throws -> any UIDriver {
        switch target.surface {
            case .web:
                return WebDriver(
                    url: target.locator,
                    viewport: options.viewport,
                    scale: options.scale,
                    persistentProfile: options.profile)
            case .mac:
                return MacDriver(
                    appLocator: target.locator, windowIndex: target.windowIndex,
                    windowTitle: target.windowTitle)
            case .sim:
                return SimDriver(deviceLocator: target.locator)
            case .live:
                return try LiveSessionDriver(name: target.locator)
        }
    }

    /// Prepare a driver, hand it to `body`, and always shut it down afterwards.
    public static func withDriver<T>(
        _ target: Target,
        options: Options = .default,
        body: (any UIDriver) async throws -> T
    ) async throws -> T {
        // `Self.` is required: inside this scope the name `driver` is the constant
        // being bound, so the unqualified call cannot resolve.
        let driver = try await MainActor.run { try Self.driver(for: target, options: options) }
        try await driver.prepare()
        do {
            let result = try await body(driver)
            await driver.shutdown()
            return result
        } catch {
            await driver.shutdown()
            throw error
        }
    }

    // MARK: - One-shot verbs

    public static func capture(
        _ target: Target, options: Options = .default, capture: CaptureOptions = .default
    ) async throws -> Capture {
        try await withDriver(target, options: options) { try await $0.capture(capture) }
    }

    public static func describe(
        _ target: Target, options: Options = .default, describe: DescribeOptions = .default
    ) async throws -> [UINode] {
        let nodes = try await withDriver(target, options: options) {
            try await $0.describe(describe)
        }
        guard let root = describe.root, !root.isEmpty else { return nodes }
        // The Mac driver re-roots its own walk, so this finds the branch already
        // sitting at the top and changes nothing. Web and the simulator build the
        // whole tree either way, so taking the branch here is the cheaper of the
        // two honest options — and it means one handle works on every surface.
        if let branch = nodes.compactMap({ $0.subtree(withID: root) }).first {
            // Bounded from the branch, not from the surface root. A driver that
            // re-rooted its own walk has already done this, and re-applying the
            // same cap to an already-capped tree changes nothing.
            return [branch.limited(toDepth: describe.maxDepth)]
        }
        // Not an error: every driver reports an unresolvable handle itself, so
        // reaching here means the branch resolved and a filter emptied it — which
        // is an ordinary "nothing matched", not a bad handle.
        return []
    }

    /// Run a sequence of actions, then capture. Batching matters: for web and
    /// simulator targets each `withDriver` costs a fresh page load or device
    /// resolution, so "click then screenshot" as two CLI calls would lose the
    /// state the click produced.
    @discardableResult
    public static func act(
        _ target: Target,
        actions: [UIAction],
        options: Options = .default,
        captureAfter: CaptureOptions? = nil
    ) async throws -> (results: [ActionResult], capture: Capture?) {
        try await withDriver(target, options: options) { driver in
            var results: [ActionResult] = []
            for action in actions {
                results.append(try await perform(action, on: driver))
            }
            var shot: Capture?
            if let captureAfter { shot = try await driver.capture(captureAfter) }
            return (results, shot)
        }
    }

    // MARK: - Seeing and acting together

    /// What ``annotatedCapture(_:options:capture:filter:maxElements:)`` produces.
    ///
    /// All three parts travel together because a caller needs all three: the
    /// boxed image to look at, the numbering to read it by, and the untouched
    /// capture to save or diff — annotations are drawn for a human eye and would
    /// poison a before/after comparison.
    public struct AnnotatedCapture: Sendable {
        /// PNG with a numbered box around each actionable element.
        public var png: Data
        /// What each number refers to, in the order they were drawn.
        public var annotations: [Annotation]
        /// The unannotated capture the boxes were drawn on.
        public var capture: Capture

        public init(png: Data, annotations: [Annotation], capture: Capture) {
            self.png = png
            self.annotations = annotations
            self.capture = capture
        }
    }

    /// Capture a target with its actionable elements boxed and numbered.
    ///
    /// Answers the awkward middle ground between "read the tree" and "look at a
    /// picture": a model can see where things are, but the handle it acts with
    /// comes from accessibility, so the action is exact even when the perception is
    /// approximate. No coordinate ever has to be guessed from a downscaled image.
    ///
    /// This is the answer for apps with poor accessibility, which in practice
    /// almost never means *missing* elements — a button is an AX element with a
    /// role, a frame and AXPress whether or not anyone gave it a label. What is
    /// missing is a name to address it by. Numbering restores that: the picture
    /// supplies the identification, accessibility supplies the action.
    public static func annotatedCapture(
        _ target: Target,
        options: Options = .default,
        capture captureOptions: CaptureOptions = .default,
        filter: String? = nil,
        maxElements: Int = 40
    ) async throws -> AnnotatedCapture {
        try await withDriver(target, options: options) { driver in
            let shot = try await driver.capture(captureOptions)
            // interestingOnly would drop exactly the elements this exists for. An
            // unlabelled button is still a real AX element with a role, a frame and
            // AXPress — it just has no name to match on, which is the usual shape of
            // "this app has poor accessibility". Filtering by actionability below
            // keeps those and drops the layout scaffolding.
            let roots = try await driver.describe(
                DescribeOptions(maxDepth: 32, interestingOnly: false, filter: filter))
            let all = roots.flatMap { $0.flattened() }

            // Only things worth touching, and only things actually visible: boxing
            // every group would bury the screen in rectangles.
            let containers: Set<String> = ["window", "group", "list", "other", "menu"]
            let actionable = all.filter { node in
                guard let frame = node.frame, !frame.isEmpty else { return false }
                // The menu bar lives outside the window, so numbering it would put
                // badges on top of unrelated pixels. Drive menus by name instead.
                if node.id.hasPrefix("mb") { return false }
                // A container's box spans everything inside it, so numbering one buries
                // the controls it holds. Keep it only if it is itself pressable.
                if containers.contains(node.role) && !node.actions.contains("AXPress") { return false }
                // Disabled controls are kept, and marked: "the button is there but
                // greyed" is exactly what a caller needs to know, and hiding it looks
                // like the control does not exist.
                return !node.actions.isEmpty || node.role == "textfield" || node.role == "cell"
            }

            // Frames are screen points on macOS; the capture starts at the window's
            // origin, so subtract it. Web and simulator frames already start there.
            let origin: Frame? =
                target.surface == .mac ? roots.first(where: { $0.role == "window" })?.frame : nil

            let annotations = actionable.prefix(maxElements).enumerated().map { index, node in
                Annotation(
                    number: index + 1, id: node.id, role: node.role,
                    label: node.enabled ? node.label : ((node.label ?? node.role) + " (disabled)"),
                    frame: node.frame ?? Frame(x: 0, y: 0, width: 0, height: 0))
            }
            let png = try ImageOps.annotate(
                shot.png, annotations: Array(annotations), scale: shot.scale, origin: origin)
            return AnnotatedCapture(png: png, annotations: Array(annotations), capture: shot)
        }
    }

    /// What is at a point, without touching it.
    ///
    /// Deliberately a query rather than an action: an agent reading a screenshot
    /// should be able to check its aim before committing, and "what is here?" is a
    /// much cheaper question than an unintended click.
    public static func elementAt(
        _ target: Target,
        x: Double,
        y: Double,
        space: CoordinateSpace = .windowPoints,
        options: Options = .default
    ) async throws -> UINode? {
        try await withDriver(target, options: options) { driver in
            let roots = try await driver.describe(
                DescribeOptions(maxDepth: 32, interestingOnly: false))
            let origin: Frame? =
                target.surface == .mac ? roots.first(where: { $0.role == "window" })?.frame : nil
            let window = origin ?? roots.first?.frame
                ?? Frame(x: 0, y: 0, width: 0, height: 0)
            let point = space.toScreenPoint(
                x: x, y: y, windowFrame: window, backingScale: 2)
            // Screen space on macOS, window space elsewhere.
            let target = target.surface == .mac ? point : (x: point.x - window.x, y: point.y - window.y)

            // Deepest match wins: the innermost element under a point is the one a
            // click would reach.
            var best: UINode?
            var bestArea = Double.greatestFiniteMagnitude
            for node in roots.flatMap({ $0.flattened() }) {
                guard let frame = node.frame, !frame.isEmpty,
                    target.x >= frame.x, target.x <= frame.x + frame.width,
                    target.y >= frame.y, target.y <= frame.y + frame.height
                else { continue }
                let area = frame.width * frame.height
                if area < bestArea {
                    bestArea = area
                    best = node
                }
            }
            return best
        }
    }

    // MARK: - Before / after

    /// Capture the "before" side of a named comparison.
    public static func before(
        session name: String,
        target: Target,
        options: Options = .default,
        capture captureOptions: CaptureOptions = .default,
        actions: [UIAction] = [],
        store: ComparisonStore = ComparisonStore()
    ) async throws -> (capture: Capture, path: URL) {
        let shot = try await withDriver(target, options: options) { driver in
            for action in actions { _ = try await perform(action, on: driver) }
            return try await driver.capture(captureOptions)
        }
        try store.recordBefore(name: name, capture: shot, target: target.description)
        return (shot, store.beforeURL(name))
    }

    /// Capture the "after" side and produce the side-by-side proof image.
    public static func after(
        session name: String,
        target: Target? = nil,
        options: Options = .default,
        capture captureOptions: CaptureOptions = .default,
        actions: [UIAction] = [],
        store: ComparisonStore = ComparisonStore()
    ) async throws -> ComparisonResult {
        // Reuse the recorded target so the second invocation only needs the
        // session name — the agent taking the "after" shot is often a later turn
        // that no longer has the target string at hand.
        let resolved: Target
        if let target {
            resolved = target
        } else if let session = try store.load(name) {
            resolved = try Target.parse(session.target)
        } else {
            throw LoupeError.failed("unknown session '\(name)' — run `loupe before` first")
        }

        let shot = try await withDriver(resolved, options: options) { driver in
            for action in actions { _ = try await perform(action, on: driver) }
            return try await driver.capture(captureOptions)
        }
        let outcome = try store.recordAfter(name: name, capture: shot)
        return ComparisonResult(
            report: outcome.report, composite: outcome.composite, path: store.compareURL(name))
    }
}
