import Foundation

/// A rectangle in the target's own coordinate space, top-left origin.
///
/// Every surface reports points, not pixels: CSS pixels for the web, AppKit
/// points for Mac windows, iOS points for the simulator. A caller can therefore
/// take a coordinate straight out of ``UINode/frame`` and hand it back in a
/// ``UIAction`` without ever knowing the backing scale.
public struct Frame: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// One element of a target's semantic tree.
///
/// This is the common denominator of three very different hierarchies — the DOM,
/// the macOS accessibility tree, and XCUIElement snapshots — reduced to what an
/// agent needs in order to decide what to touch next.
public struct UINode: Codable, Hashable, Sendable {
    /// Addressable handle, unique within one `describe` result. Callers pass this
    /// back in a ``UIAction``. Handles are *not* stable across calls: re-describe
    /// before acting, which is what makes stale-element bookkeeping unnecessary.
    public var id: String
    /// Normalized role: `button`, `link`, `textfield`, `text`, `image`, `window`,
    /// `menu`, `menuitem`, `checkbox`, `list`, `cell`, `group`, `other`, …
    public var role: String
    /// Native role, verbatim, for when the normalization loses something.
    public var rawRole: String?
    public var label: String?
    public var value: String?
    public var identifier: String?
    public var frame: Frame?
    public var enabled: Bool
    public var focused: Bool
    /// Actions this element actually advertises. Never assume: on macOS a text
    /// area may offer only `AXShowMenu`, and pressing an unsupported action is a
    /// silent no-op.
    public var actions: [String]
    public var children: [UINode]
    /// Set when this node has content that was not walked. Its presence is also
    /// what keeps an unnamed container alive: a node that is hiding something is
    /// interesting by definition, whatever its label says.
    public var elided: Elision?

    public init(
        id: String,
        role: String,
        rawRole: String? = nil,
        label: String? = nil,
        value: String? = nil,
        identifier: String? = nil,
        frame: Frame? = nil,
        enabled: Bool = true,
        focused: Bool = false,
        actions: [String] = [],
        children: [UINode] = [],
        elided: Elision? = nil
    ) {
        self.id = id
        self.role = role
        self.rawRole = rawRole
        self.label = label
        self.value = value
        self.identifier = identifier
        self.frame = frame
        self.enabled = enabled
        self.focused = focused
        self.actions = actions
        self.children = children
        self.elided = elided
    }

    /// Depth-first walk including `self`.
    public func flattened() -> [UINode] {
        [self] + children.flatMap { $0.flattened() }
    }

    /// The subtree rooted at `handle`, or nil if this tree does not contain it.
    ///
    /// The fallback for surfaces that cannot cheaply re-root a walk: describe
    /// everything, then hand back the one branch that was asked for. Costs the
    /// full walk, so a driver that *can* start lower down should.
    public func subtree(withID handle: String) -> UINode? {
        if id == handle { return self }
        for child in children {
            if let hit = child.subtree(withID: handle) { return hit }
        }
        return nil
    }

    /// Case-insensitive substring match over label, value and identifier.
    public func matches(_ needle: String) -> Bool {
        let lowered = needle.lowercased()
        return [label, value, identifier, id]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(lowered) }
    }
}

/// A captured image plus what it took to get it.
public struct Capture: Sendable {
    /// PNG bytes.
    public var png: Data
    /// Size in points (see ``Frame``).
    public var pointSize: CGSize
    /// Backing scale the pixels were rendered at (2.0 on Retina, 3.0 on most
    /// iPhone simulators).
    public var scale: Double
    /// Human-readable description of what was captured.
    public var target: String
    public var timestamp: Date
    /// Free-form notes worth surfacing next to the image (e.g. "window was
    /// occluded", "simulator booted on demand").
    public var notes: [String]

    public init(
        png: Data,
        pointSize: CGSize,
        scale: Double,
        target: String,
        timestamp: Date = Date(),
        notes: [String] = []
    ) {
        self.png = png
        self.pointSize = pointSize
        self.scale = scale
        self.target = target
        self.timestamp = timestamp
        self.notes = notes
    }

    public var pixelSize: CGSize {
        CGSize(width: pointSize.width * scale, height: pointSize.height * scale)
    }
}

/// Something to do to a target.
///
/// Kept deliberately small. Anything a driver cannot honor throws
/// ``LoupeError/unsupported(_:)`` rather than silently degrading — a no-op that
/// reports success is the single worst failure mode for a verification tool.
public enum UIAction: Sendable {
    /// Activate an element (AXPress, a full synthetic pointer sequence on the
    /// web, a tap on iOS).
    case press(node: String)
    /// Set a value directly, bypassing keystrokes. Full Unicode, no focus needed
    /// on macOS.
    case setValue(node: String, value: String)
    /// Click at a point. See ``CoordinateSpace`` — the default is window points,
    /// the same space ``Capture/pointSize`` reports.
    case click(x: Double, y: Double, space: CoordinateSpace, viaCursor: Bool)
    /// Type into whatever currently has focus.
    case type(String)
    /// A named key: `return`, `tab`, `escape`, `delete`, `up`, `down`, `left`,
    /// `right`, `space`, or `cmd+s`-style combinations.
    case key(String)
    case scroll(dx: Double, dy: Double)
    /// Bring a specific element into view.
    ///
    /// Almost always what you actually want. Scrolling by a distance means
    /// guessing how far, checking, and guessing again; the element you care about
    /// is right there in the tree with a frame, so ask the app to reveal it and
    /// let it work out the arithmetic. On macOS this is the `AXScrollToVisible`
    /// action, which is what VoiceOver uses to follow focus.
    case scrollTo(node: String)
    /// Web: navigate. Simulator/Mac: open a URL or deep link in the target.
    case navigate(String)
    /// Run JavaScript (web only) and return its result as a string.
    case evaluate(String)
    /// Launch or focus an application (bundle id, app name, or `.app` path).
    case launch(String)
    case terminate(String)
    /// Wait until the screen stops changing, or `timeout` elapses.
    case settle(timeout: Double)
    /// Wait for one of several elements to appear (and be enabled), or for one to
    /// disappear.
    ///
    /// `settle` only watches pixels, which is a blunt instrument: a spinner
    /// animating forever never settles, and a screen that renders in two paints
    /// looks settled between them.
    ///
    /// `failIf` is what makes this usable for real flows. "Wait for the dashboard"
    /// after a login burns the whole timeout when the password was wrong, and then
    /// reports a timeout — the least useful description of what happened. Racing
    /// the expected outcome against the known failures returns in the time the app
    /// takes to reject you, and says which one it was and what it said.
    case waitFor(nodes: [String], failIf: [String], gone: Bool, timeout: Double)
}

public struct ActionResult: Sendable {
    // `ok` reads perfectly at every call site (`if !result.ok`) and is public API
    // that all four drivers construct and the CLI consumes — a longer name here
    // would be a source break bought with no clarity.
    public var ok: Bool
    public var message: String
    /// Anything the action produced (JS return value, launched pid, …).
    public var payload: String?

    public init(ok: Bool = true, message: String, payload: String? = nil) {
        self.ok = ok
        self.message = message
        self.payload = payload
    }
}

public struct CaptureOptions: Sendable {
    /// Capture only this sub-rectangle, in target points.
    public var region: Frame?
    /// Web only: capture the full scrollable page rather than the viewport.
    public var fullPage: Bool
    /// Wait for the screen to stop changing first (recommended before any
    /// before/after pair — animations are the main source of false diffs).
    public var settle: Bool
    /// Seconds to wait for settling.
    public var settleTimeout: Double

    public init(
        region: Frame? = nil,
        fullPage: Bool = false,
        settle: Bool = true,
        settleTimeout: Double = 3.0
    ) {
        self.region = region
        self.fullPage = fullPage
        self.settle = settle
        self.settleTimeout = settleTimeout
    }

    public static let `default` = CaptureOptions()
}

public struct DescribeOptions: Sendable {
    /// Hard cap on tree depth. Deep hierarchies (React Native, big web apps) are
    /// where snapshot APIs time out, so this is a cap, not a hint.
    public var maxDepth: Int
    /// Drop nodes with no label, value or identifier *and* no actions — pure
    /// layout scaffolding that costs tokens and tells an agent nothing.
    public var interestingOnly: Bool
    /// Only return nodes matching this text.
    public var filter: String?
    /// How much of the surface to expand.
    public var scope: Scope
    /// Start the walk at this handle instead of the top, so a caller can open one
    /// branch without paying for the whole tree again.
    public var root: String?

    /// Which trees a describe expands.
    ///
    /// The default is ``all`` and must stay that way: ``UIDriver/resolve(_:options:)``
    /// runs through `describe`, so a default that skipped the menu bar would make
    /// `press "Quit"` fail — and, worse, would drop menu items from the
    /// near-miss list, turning "here are the three things that nearly match" into
    /// "nothing matches" for an element that plainly exists. Presentation
    /// entry points opt into ``primary``; resolution never does.
    public enum Scope: String, Sendable, Codable {
        /// Everything the surface exposes, menu bar included.
        case all
        /// The window's own content. Peripheral trees are named and counted, not
        /// expanded — on macOS the menu bar is 73% of a default describe and is
        /// almost never what was being asked about.
        case primary
    }

    public init(
        maxDepth: Int = 24, interestingOnly: Bool = true, filter: String? = nil,
        scope: Scope = .all, root: String? = nil
    ) {
        self.maxDepth = maxDepth
        self.interestingOnly = interestingOnly
        self.filter = filter
        self.scope = scope
        self.root = root
    }

    public static let `default` = DescribeOptions()
}

/// Which coordinate system a point is expressed in.
///
/// This exists because there are four plausible answers and picking wrong puts
/// the click somewhere else entirely, usually silently. An agent reading a
/// screenshot measures pixels; a Retina window has twice as many of those as it
/// has points; MCP hands the model a *downscaled* image, so even its pixels are
/// not the capture's pixels; and the accessibility tree reports global screen
/// coordinates.
public enum CoordinateSpace: String, Codable, Sendable, CaseIterable {
    /// Window-relative points, origin at the window's top-left. Matches
    /// ``Capture/pointSize`` and is the default.
    case windowPoints
    /// Window-relative pixels of the full-resolution capture. Divide by the
    /// capture's scale to get points.
    case windowPixels
    /// Fractions of the window, 0…1, origin top-left.
    ///
    /// The only space that survives rescaling, so it is the right one to use when
    /// working from an image whose size you are not certain of — which includes
    /// every image delivered over MCP, since those are downscaled to keep the
    /// token cost sane.
    case normalized
    /// Global screen points, origin at the top-left of the main display. The same
    /// space as ``UINode/frame`` on macOS.
    case screenPoints

    /// Convert a point in this space to global screen points.
    ///
    /// Pure arithmetic on the window's frame, kept here rather than in the driver
    /// so it can be tested without a running app — an off-by-one scale factor puts
    /// every click at double or half the intended position, and that is not
    /// something to discover in front of a user's app.
    public func toScreenPoint(
        x: Double, y: Double, windowFrame: Frame, backingScale: Double
    ) -> (x: Double, y: Double) {
        switch self {
            case .screenPoints:
                return (x, y)
            case .windowPoints:
                return (windowFrame.x + x, windowFrame.y + y)
            case .windowPixels:
                let scale = backingScale > 0 ? backingScale : 1
                return (windowFrame.x + x / scale, windowFrame.y + y / scale)
            case .normalized:
                return (windowFrame.x + x * windowFrame.width, windowFrame.y + y * windowFrame.height)
        }
    }

    /// Short form accepted in step syntax: `click:pt:…`, `px:`, `n:`, `screen:`.
    public static func parse(_ token: String) -> CoordinateSpace? {
        switch token.lowercased() {
            case "pt", "point", "points", "windowpoints": return .windowPoints
            case "px", "pixel", "pixels", "windowpixels": return .windowPixels
            case "n", "norm", "normalized", "fraction": return .normalized
            case "screen", "screenpoints", "global": return .screenPoints
            default: return nil
        }
    }
}

public enum LoupeError: LocalizedError, Sendable {
    case unsupported(String)
    case targetNotFound(String)
    case nodeNotFound(String)
    case permissionDenied(String, remedy: String)
    case timeout(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
            case .unsupported(let what):
                return "Not supported on this target: \(what)"
            case .targetNotFound(let what):
                return "No such target: \(what)"
            case .nodeNotFound(let what):
                return "No element matching: \(what)"
            case .permissionDenied(let what, let remedy):
                return "Permission denied: \(what)\n  Fix: \(remedy)"
            case .timeout(let what):
                return "Timed out: \(what)"
            case .failed(let what):
                return what
        }
    }
}
