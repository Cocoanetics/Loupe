import Foundation
import LoupeCore
import WebKit

// What the page says about itself, and how the driver waits for it to stop
// saying something different.

extension WebDriver {

    /// What the page says about itself. Cheap enough to poll.
    struct PageState: Decodable, Sendable {
        var readyState: String
        var animations: Int
        var rafRequested: Int
        var rafDelivered: Int
        var canvases: Int
        var scrollHeight: Double
        var scrollWidth: Double
        var devicePixelRatio: Double
        var innerWidth: Double
        var innerHeight: Double
        var scrollX: Double
        var scrollY: Double
        var title: String
        var url: String
    }

    func readPageState() async throws -> PageState {
        guard let webView else { throw LoupeError.failed("the web view is not ready") }
        let json = try await loupeEvaluate(webView, WebScripts.readiness)
        let envelope = try decodeEnvelope(json)
        guard let payload = envelope.payload, let data = payload.data(using: .utf8) else {
            throw LoupeError.failed("could not read the page state")
        }
        do {
            return try JSONDecoder().decode(PageState.self, from: data)
        } catch {
            throw LoupeError.failed("could not read the page state: \(error)")
        }
    }

    /// Wait until two consecutive low-resolution snapshots are byte-identical and
    /// the document reports itself complete.
    ///
    /// Pixels rather than a readiness flag: `readyState === "complete"` fires long
    /// before a font swap, a lazy image, or a fade-in has finished, and those are
    /// exactly the things that produce a false diff. Returns the notes worth
    /// surfacing — empty means it settled.
    @discardableResult
    func settlePage(timeout: Double) async throws -> [String] {
        guard let webView else { throw LoupeError.failed("the web view is not ready") }
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        var previous: Data?
        var probes = 0

        while true {
            let state = try? await readPageState()
            let quiet = (state?.readyState == "complete") && !webView.isLoading
            let probe = try? await loupeSnapshot(webView, rect: nil, snapshotWidth: settleProbeWidth)
            probes += 1

            if quiet, let probe, let previous, probe.png == previous {
                return []
            }
            previous = probe?.png

            if Date() >= deadline {
                let reason = stillChangingReason(after: timeout, state: state, webView: webView)
                return ["\(reason) (\(probes) probes) — the capture may differ from the next one"]
            }
            try? await Task.sleep(nanoseconds: UInt64(settleInterval * 1_000_000_000))
        }
    }

    /// Why the page was still moving when the settle timeout ran out. Naming the
    /// cause is the difference between "it was slow" and "there is a spinner".
    private func stillChangingReason(after timeout: Double, state: PageState?, webView: WKWebView)
        -> String {
        var reason = "the page was still changing after \(formatSeconds(timeout))s"
        guard let state else { return reason }
        if state.readyState != "complete" { reason += "; document.readyState is \(state.readyState)" }
        if webView.isLoading { reason += "; a resource is still loading" }
        if state.animations > 0 { reason += "; \(state.animations) running animation(s)" }
        return reason
    }

    /// Whole seconds when the timeout is whole, one decimal otherwise.
    private func formatSeconds(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
