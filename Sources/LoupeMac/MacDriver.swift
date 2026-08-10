import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LoupeCore

/// Drives a macOS application through the accessibility API, from the
/// background, without ever taking focus away from the human at the keyboard.
///
/// The whole design follows from one promise: the target app is never
/// activated, never raised, and the user's cursor and typing focus are never
/// touched. That rules out the obvious implementations and leaves a narrow but
/// verified path:
///
/// - **Pixels** come from ScreenCaptureKit, the only API that still renders a
///   window that is minimized, hidden, occluded or on another Space.
/// - **Structure** comes from the accessibility tree, which answers fully for
///   background and even hidden applications.
/// - **Actions** are `AXPress` and `AXUIElementSetAttributeValue`, plus key
///   events posted straight to the process. Synthetic *mouse* events are not
///   used: posted per-process they arrive with no window attached and AppKit
///   discards them before `mouseDown:` ever runs, so a click would look like a
///   success and do nothing.
///
/// Coordinates: every point in this driver — ``UINode/frame``,
/// ``CaptureOptions/region`` and `click(x:y:)` — is in **global screen points
/// with a top-left origin**, which is what the accessibility API natively
/// reports. That means a node frame can be handed straight back as a click
/// target or a crop region. Each ``Capture`` also notes the window's own screen
/// frame, so window-relative math is possible when a caller needs it.
///
/// Main-actor isolated because it touches AppKit (`NSWorkspace`,
/// `NSRunningApplication`) and holds non-`Sendable` `AXUIElement` handles; the
/// isolation is what makes the driver `Sendable` enough to satisfy ``UIDriver``.
///
/// The implementation is split by responsibility across `MacDriver+…` files —
/// capture, describe, actions, clicking, scrolling, windows, applications and
/// target resolution — which is why the members shared between them are
/// module-internal rather than private.
@MainActor
public final class MacDriver: UIDriver {
    /// App name ("Safari"), bundle id ("com.apple.Safari") or "pid:1234".
    nonisolated public let appLocator: String
    /// Index into the app's `AXWindows`, nil meaning its frontmost window.
    nonisolated public let windowIndex: Int?

    var runningApplication: NSRunningApplication?
    var applicationElement: AXUIElement?

    /// Whether the Chromium wake-up has already been tried for this driver, so a
    /// genuinely empty window costs the extra wait only once.
    var hasWokenChromium = false
    var windowElement: AXUIElement?
    let windowTitle: String?
    var resolvedWindowIndex = 0
    /// Node id → element, rebuilt by every ``describe(_:)``. Ids are also
    /// re-walkable paths, so a handle that predates the current cache still
    /// resolves; see ``element(atPath:)``.
    var nodeIndex: [String: AXUIElement] = [:]

    var windowRootID: String { "w\(resolvedWindowIndex)" }
    let menuRootID = "mb"

    /// `nonisolated` so a driver factory does not have to be main-actor isolated
    /// just to construct one; every method that touches AppKit or the
    /// accessibility tree hops to the main actor on its own.
    nonisolated public init(
        appLocator: String, windowIndex: Int? = nil, windowTitle: String? = nil
    ) {
        self.appLocator = appLocator
        self.windowIndex = windowIndex
        self.windowTitle = windowTitle
    }

    nonisolated public var targetDescription: String {
        if let windowIndex { return "mac:\(appLocator)#\(windowIndex)" }
        if let windowTitle { return "mac:\(appLocator)#\(windowTitle)" }
        return "mac:\(appLocator)"
    }

    // MARK: - Lifecycle

    /// Find the application and its window. Never launches anything: an implicit
    /// launch would put a new app on the user's screen as a side effect of a
    /// read-only verb. Use `perform(.launch(…))` when that is actually wanted.
    ///
    /// A target that is not running is remembered rather than thrown, because
    /// `.launch` is exactly the verb you reach for when it is not running yet —
    /// failing here would make launching an app impossible. Every verb that needs
    /// a live application rethrows it via ``requireResolved()``.
    public func prepare() async throws {
        try ensureTrusted()
        do {
            try resolveApplication()
            enableManualAccessibility()
            try resolveWindow()
            resolutionFailure = nil
        } catch {
            resolutionFailure = error
        }
    }

    /// Ask a Chromium-based app to build its accessibility tree.
    ///
    /// Electron and every other Chromium shell keep their tree switched off
    /// until an assistive client asks for it, because building it is expensive.
    /// Until then the whole interface reports as anonymous nested groups — every
    /// button, field and label simply absent — which reads as "this app has poor
    /// accessibility" when in fact nothing has been turned on yet.
    ///
    /// `AXManualAccessibility` is the documented switch. Apps that do not
    /// implement it return an error, which is why the result is discarded: this
    /// is a request, not a requirement.
    func enableManualAccessibility() {
        guard let applicationElement else { return }
        AXAPI.set(applicationElement, "AXManualAccessibility", kCFBooleanTrue)
    }

    /// Why the target could not be resolved, if it could not.
    private var resolutionFailure: Error?

    /// Rethrow the deferred resolution failure for verbs that cannot proceed
    /// without a running application.
    func requireResolved() throws {
        if let resolutionFailure { throw resolutionFailure }
    }

    /// Re-resolve after something changed the world, e.g. a launch.
    func reresolve() async throws {
        resolutionFailure = nil
        try resolveApplication()
        try resolveWindow()
    }

    /// Nothing is held open — no window server session, no simulator, no web
    /// view. Clearing the caches is all there is to do, and doing it twice is
    /// harmless.
    public func shutdown() async {
        nodeIndex.removeAll()
        windowElement = nil
        applicationElement = nil
        runningApplication = nil
    }
}
