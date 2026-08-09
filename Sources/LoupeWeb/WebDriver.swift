import AppKit
import Foundation
import LoupeCore
import WebKit

/// Drives a page in a `WKWebView` that lives in a window the user never sees.
///
/// `WKWebView` is not a lookalike of Safari — it is the same WebKit binary, so
/// the layout, fonts, and CSS support are Safari's. The differences that matter
/// are configuration, and this driver closes them deliberately:
///
/// * the user-agent gets the `Version/… Safari/…` tokens that a bare `WKWebView`
///   omits, because plenty of sites branch on them;
/// * media is held to `.all` user-action-gated playback, which is *stricter* than
///   Safari on purpose — an autoplaying hero video makes every screenshot differ
///   from every other one, which destroys the before/after comparison this whole
///   tool exists for;
/// * `_setControlledByAutomation` is never called: it sets
///   `navigator.webdriver = true`, and pages behave differently when they think
///   they are being automated. Verified `navigator.webdriver === false` here.
///
/// ### Two things to know before trusting a capture
///
/// **The page is in the "hidden" activity state.** The window is never ordered
/// in, so WebKit gives the page no rendering updates. Measured on macOS 26.6:
/// `requestAnimationFrame` callbacks are never delivered, CSS animations stay
/// frozen at `currentTime` 0, `document.visibilityState` is `"hidden"`, and
/// `document.hasFocus()` is `false`. `setTimeout`/`setInterval` still run
/// (throttled to roughly 8 Hz), and DOM changes they make *do* appear in
/// snapshots. The upside is that captures are unusually deterministic — there is
/// no animation noise to produce false diffs. The cost is that anything drawn on
/// a frame loop (canvas, WebGL, chart libraries, JS-driven motion) is captured at
/// its first frame. ``capture(_:)`` detects this and says so in
/// ``Capture/notes``; it never pretends the frame is live.
///
/// **Element handles are per-page.** ``describe(_:)`` stamps a `data-loupe-id`
/// attribute on each element it reports and the handle carries the navigation
/// generation, so a handle used after the page changed is reported as stale
/// rather than silently resolving to whatever now sits in that position.
@MainActor
public final class WebDriver: UIDriver {

    // MARK: - Configuration

    /// The URL ``prepare()`` loads.
    public nonisolated let url: String
    /// Layout viewport in CSS pixels. Everything reported by ``describe(_:)`` and
    /// every coordinate accepted by ``UIAction/click(x:y:)`` is in this space.
    public nonisolated let viewport: CGSize
    /// Requested backing scale for captures. The achieved scale is measured from
    /// the returned image and reported in ``Capture/scale`` — they can differ when
    /// the Mac's main display is not Retina, and a lie there would silently corrupt
    /// every coordinate a caller derives from a screenshot.
    public nonisolated let scale: Double
    /// Name of a persistent cookie/localStorage profile, or `nil` for a throwaway
    /// session. Same name, same data on the next run — which is how an agent stays
    /// logged in across separate CLI invocations.
    public nonisolated let persistentProfile: String?

    /// Seconds a navigation may take before it is reported as a timeout.
    let navigationTimeout: Double = 30

    /// Snapshot width used for the settle comparison. Small on purpose: settling
    /// takes several snapshots and only needs to detect *change*, not resolve it.
    let settleProbeWidth: Double = 320

    /// Interval between settle probes.
    let settleInterval: Double = 0.2

    // MARK: - State
    //
    // Internal rather than private because this type is spelled out across several
    // files (capture, describe, actions, page state) and `private` is file-scoped.

    nonisolated let liveURL: LockedString

    var webView: WKWebView?
    var window: OffscreenWindow?
    var navigator: NavigationCoordinator?
    var dialogHandler: DialogCoordinator?
    private var pendingNotes: [String] = []
    private var didShutDown = false

    /// One-at-a-time gate. `capture(fullPage:)` resizes the web view and puts it
    /// back; a second operation interleaving at an `await` inside that window would
    /// see a viewport that is temporarily 6,000 px tall. The gate is cheap and
    /// removes the whole class of problem.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - Life cycle

    /// - Parameters:
    ///   - url: An absolute URL. A bare `example.com` is treated as `https://`,
    ///     and `file://` URLs are loaded with read access to their directory so
    ///     sibling CSS and scripts resolve.
    ///   - viewport: Layout size in CSS pixels.
    ///   - scale: Requested backing scale (2.0 renders Retina-density pixels).
    ///   - persistentProfile: Name of a persistent website-data store, or `nil`.
    public nonisolated init(
        url: String,
        viewport: CGSize = CGSize(width: 1280, height: 900),
        scale: Double = 2.0,
        persistentProfile: String? = nil
    ) {
        self.url = url
        self.viewport = CGSize(
            width: max(viewport.width.rounded(), 1), height: max(viewport.height.rounded(), 1))
        self.scale = scale > 0 ? scale : 1
        self.persistentProfile = persistentProfile
        self.liveURL = LockedString(WebDriver.normalize(url) ?? url)
    }

    public nonisolated var targetDescription: String { "web:\(liveURL.value)" }

    /// Where the web view actually is right now, which is not the same as ``url``
    /// after a redirect, a press on a link, or a `navigate` action.
    public nonisolated var currentURL: String { liveURL.value }

    /// Create the window and web view, load the URL, and wait for the navigation
    /// to complete. Idempotent: calling it twice does not reload.
    public func prepare() async throws {
        try await exclusive { try await self.ensureReady() }
    }

    /// Tear down the web view and window. Safe to call twice; after it, every verb
    /// reports that the driver is finished rather than quietly restarting.
    public func shutdown() async {
        await acquire()
        defer { release() }
        guard !didShutDown else { return }
        didShutDown = true
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        window?.contentView = nil
        window?.close()
        webView = nil
        window = nil
        navigator = nil
        dialogHandler = nil
    }

    // MARK: - Bring-up

    var generation: Int { navigator?.generation ?? 1 }

    func ensureReady() async throws {
        if didShutDown {
            throw LoupeError.failed("this WebDriver was shut down — create a new one to load a page again")
        }
        guard webView == nil else {
            if let navigator, navigator.contentProcessDidTerminate {
                // The view is still there but its content process is gone, which renders
                // as a blank white page. Reload the URL we were on and say so.
                navigator.acknowledgeCrash()
                pendingNotes.append(
                    "the web content process had crashed; the page was reloaded before this call, so any "
                        + "state the page held in memory is gone")
                try await navigate(to: currentURL)
            }
            return
        }
        try await bootstrap()
    }

    private func bootstrap() async throws {
        pendingNotes += prepareApplicationForOffscreenUse()

        let configuration = WKWebViewConfiguration()
        if let persistentProfile {
            configuration.websiteDataStore = WKWebsiteDataStore(
                forIdentifier: websiteDataStoreIdentifier(forProfile: persistentProfile))
        } else {
            configuration.websiteDataStore = .nonPersistent()
        }
        // A default WKWebView user-agent has no `Version/` or `Safari/` token, and
        // enough sites branch on those that the page you capture would not be the
        // page a human sees.
        configuration.applicationNameForUserAgent = "Version/26.5 Safari/605.1.15"
        // Stricter than Safari, deliberately: a playing video means every screenshot
        // differs from every other one.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.isElementFullscreenEnabled = true

        let frame = CGRect(origin: .zero, size: viewport)
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.autoresizingMask = [.width, .height]

        let navigator = NavigationCoordinator()
        navigator.attach(to: webView)
        let dialogHandler = DialogCoordinator()
        webView.uiDelegate = dialogHandler

        // Borderless, never ordered in, and never made key: nothing appears on the
        // user's screen and nothing steals focus.
        let window = OffscreenWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView

        self.webView = webView
        self.window = window
        self.navigator = navigator
        self.dialogHandler = dialogHandler

        do {
            try await navigate(to: url)
        } catch {
            // A driver that failed to load is not usable; do not leave a half-built
            // window behind for the next call to trip over.
            await teardownAfterFailedBootstrap()
            throw error
        }
    }

    private func teardownAfterFailedBootstrap() async {
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        window?.contentView = nil
        window?.close()
        webView = nil
        window = nil
        navigator = nil
        dialogHandler = nil
    }

    /// Normalize a caller-supplied target into something `URL` accepts.
    private nonisolated static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return trimmed }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).absoluteString
        }
        // A bare host is what people type; assume the secure scheme.
        return "https://" + trimmed
    }

    func navigate(to raw: String) async throws {
        guard let webView, let navigator else {
            throw LoupeError.failed("the web view is not ready")
        }
        guard let normalized = WebDriver.normalize(raw), let url = URL(string: normalized) else {
            throw LoupeError.targetNotFound("\(raw) is not a URL this driver can load")
        }
        try await navigator.awaitNavigation(
            timeout: navigationTimeout, describing: "loading \(url.absoluteString)"
        ) {
            if url.isFileURL {
                // `loadFileURL` also grants read access to the containing directory, so
                // the page's own stylesheets and scripts resolve; a plain request would
                // load the HTML and then silently drop every sibling resource.
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                webView.load(URLRequest(url: url))
            }
        }
        // Redirects mean the URL we asked for is not necessarily where we landed.
        if let state = try? await readPageState() {
            liveURL.value = state.url
        } else {
            liveURL.value = url.absoluteString
        }
    }

    // MARK: - Notes

    /// Hand over the notes bring-up collected, so they ride out on the next capture
    /// rather than being lost or repeated.
    func drainNotes() -> [String] {
        defer { pendingNotes = [] }
        return pendingNotes
    }

    // MARK: - Exclusion gate

    private func acquire() async {
        while busy {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append(continuation)
            }
        }
        busy = true
    }

    private func release() {
        busy = false
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    /// Run `body` with the driver to itself. Every public verb goes through this,
    /// and nothing inside one may call another — see `describeUnlocked`.
    func exclusive<T>(_ body: () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }
}
