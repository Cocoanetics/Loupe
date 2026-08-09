import AppKit
import Foundation
import LoupeCore
import WebKit

// Taking the picture, and everything that has to be true before it is worth
// taking: the page has stopped moving, the viewport is the size the caller asked
// for, and whatever this environment cannot render has been said out loud.

extension WebDriver {

    // MARK: - Capture

    public func capture(_ options: CaptureOptions) async throws -> Capture {
        try await exclusive { try await self.captureUnlocked(options) }
    }

    private func captureUnlocked(_ options: CaptureOptions) async throws -> Capture {
        try await ensureReady()
        guard let webView, let window else {
            throw LoupeError.failed("the web view went away before the capture")
        }

        var notes = drainNotes()
        if options.settle { notes += try await settlePage(timeout: options.settleTimeout) }

        let state = try await readPageState()
        notes += preflightNotes(for: state)

        let attempt = try await takeCapture(
            webView: webView, window: window, state: state, options: options)
        notes += attempt.notes

        let achieved = Double(attempt.snapshot.pixelWidth) / max(attempt.pointRect.width, 1)
        notes += scaleNotes(achieved: achieved, state: attempt.state)
        notes += dialogHandler?.drainDialogs() ?? []

        return Capture(
            png: attempt.snapshot.png,
            pointSize: attempt.pointRect.size,
            scale: achieved,
            target: targetDescription + (options.fullPage ? " (full page)" : ""),
            notes: notes)
    }

    /// One snapshot and the context needed to report it honestly: the CSS-pixel
    /// area it covers, the page state it was taken at, and what the caller has to
    /// be told about how it was produced.
    private struct CaptureAttempt {
        var snapshot: SnapshotResult
        var pointRect: CGRect
        var state: PageState
        var notes: [String]
    }

    /// Resize if this is a full-page capture, clip to the requested region, take
    /// the picture — and put the layout back whatever happens.
    private func takeCapture(
        webView: WKWebView, window: OffscreenWindow, state: PageState, options: CaptureOptions
    ) async throws -> CaptureAttempt {
        guard options.fullPage else {
            let area = try clipRegion(
                options.region, to: CGRect(origin: .zero, size: webView.bounds.size))
            return CaptureAttempt(
                snapshot: try await snapshotImage(webView, window, of: area.rect),
                pointRect: area.rect, state: state, notes: area.notes)
        }
        let restoreHeight = webView.bounds.height
        let restoreScroll = CGPoint(x: state.scrollX, y: state.scrollY)
        do {
            let page = try await growToDocumentHeight(
                webView: webView, window: window, state: state, options: options)
            let area = try clipRegion(options.region, to: page.rect)
            let snapshot = try await snapshotImage(webView, window, of: area.rect)
            await restoreLayout(height: restoreHeight, scroll: restoreScroll)
            return CaptureAttempt(
                snapshot: snapshot, pointRect: area.rect, state: page.state,
                notes: page.notes + area.notes)
        } catch {
            await restoreLayout(height: restoreHeight, scroll: restoreScroll)
            throw error
        }
    }

    /// The area a full-page capture should cover, plus the page as it stands after
    /// the re-layout that produced it.
    private struct FullPageLayout {
        var rect: CGRect
        var state: PageState
        var notes: [String]
    }

    /// Grow the web view to the document height.
    ///
    /// The alternative, `createPDF`, re-renders through the print path — vector
    /// output, `@media print` styles, pagination, and dropped fixed elements — so
    /// its pixels are not comparable with a viewport capture, and comparability is
    /// the point.
    private func growToDocumentHeight(
        webView: WKWebView, window: OffscreenWindow, state: PageState, options: CaptureOptions
    ) async throws -> FullPageLayout {
        // The cap keeps the pixel height inside WebKit's surface limit; a taller
        // request comes back as a failed snapshot with no explanation.
        let cap = 16384.0 / max(scale, 1)
        _ = try? await loupeEvaluate(webView, WebScripts.scrollTo(x: 0, y: 0))
        var height = min(max(state.scrollHeight, viewportHeight(webView)), cap)
        window.setContentSize(CGSize(width: viewport.width, height: height))
        // Re-layout can change the height (lazy images below the fold now have a
        // box, viewport-height rules resolve differently), so measure again.
        _ = try? await settlePage(timeout: min(options.settleTimeout, 2))
        let settled = try await readPageState()
        if settled.scrollHeight > height + 1, height < cap {
            height = min(settled.scrollHeight, cap)
            window.setContentSize(CGSize(width: viewport.width, height: height))
            _ = try? await settlePage(timeout: min(options.settleTimeout, 1))
        }

        var notes: [String] = []
        if settled.scrollHeight > cap + 1 {
            notes.append(
                String(
                    format: "document is %.0f CSS px tall; captured the top %.0f px (a taller image "
                        + "exceeds WebKit's snapshot surface limit)", settled.scrollHeight, cap))
        }
        notes.append(
            "full-page capture resizes the viewport to the document height: position:fixed elements "
                + "appear once at the top, and any 100vh or viewport media-query layout reflows")
        return FullPageLayout(
            rect: CGRect(x: 0, y: 0, width: viewport.width, height: height),
            state: settled,
            notes: notes)
    }

    /// Intersect a caller-supplied region with the area actually being captured.
    private func clipRegion(_ region: Frame?, to pointRect: CGRect) throws
        -> (rect: CGRect, notes: [String]) {
        guard let region else { return (pointRect, []) }
        let wanted = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
        let clipped = wanted.intersection(pointRect)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else {
            throw LoupeError.failed(
                "region \(Int(wanted.minX)),\(Int(wanted.minY)) \(Int(wanted.width))×\(Int(wanted.height)) "
                    + "does not overlap the \(Int(pointRect.width))×\(Int(pointRect.height)) CSS-pixel "
                    + "capture area")
        }
        guard clipped != wanted else { return (clipped, []) }
        return (
            clipped,
            [
                "region was clipped to the capture area: \(Int(clipped.width))×\(Int(clipped.height)) "
                    + "at \(Int(clipped.minX)),\(Int(clipped.minY))"
            ]
        )
    }

    /// Ask for the snapshot width that lands on the requested scale.
    ///
    /// pixels = points × backingScaleFactor, so the width is derived from the
    /// window's real backing scale rather than assumed. The caller still measures
    /// what came back — see `loupeSnapshot`.
    private func snapshotImage(_ webView: WKWebView, _ window: OffscreenWindow, of pointRect: CGRect)
        async throws -> SnapshotResult {
        let backing = window.backingScaleFactor
        let wantedWidth = pointRect.width * scale / max(backing, 0.5)
        let snapshotWidth = abs(wantedWidth - pointRect.width) > 0.5 ? wantedWidth : nil
        return try await loupeSnapshot(webView, rect: pointRect, snapshotWidth: snapshotWidth)
    }

    // MARK: - Notes

    /// What is true about the page before anything is captured.
    private func preflightNotes(for state: PageState) -> [String] {
        var notes = renderingWarnings(for: state)
        if let status = navigator?.lastStatusCode, status >= 400 {
            notes.append(
                "the server answered HTTP \(status) — this is the error page, not the page you wanted")
        }
        return notes
    }

    /// Notes about what this environment cannot render, so a caller never treats a
    /// frozen canvas as a true picture of the page.
    private func renderingWarnings(for state: PageState) -> [String] {
        var notes: [String] = []
        let starved = state.rafRequested > 0 && state.rafDelivered == 0
        if starved, state.canvases > 0 || state.animations > 0 {
            var what: [String] = []
            if state.canvases > 0 { what.append("\(state.canvases) canvas element(s)") }
            if state.animations > 0 { what.append("\(state.animations) running animation(s)") }
            notes.append(
                "the page has \(what.joined(separator: " and ")) but WebKit delivers no animation frames to an "
                    + "offscreen web view — anything drawn on a frame loop is frozen at its first frame")
        }
        return notes
    }

    /// The image versus what was asked for. A silent difference here would corrupt
    /// every coordinate a caller derives from the screenshot.
    private func scaleNotes(achieved: Double, state: PageState) -> [String] {
        var notes: [String] = []
        if abs(achieved - scale) > 0.01 {
            notes.append(
                String(format: "captured at %.2f× rather than the requested %.2f×", achieved, scale))
        }
        if abs(state.devicePixelRatio - achieved) > 0.01 {
            notes.append(
                String(
                    format: "the page laid itself out for devicePixelRatio %.0f while the image is %.2f× — "
                        + "responsive images may be the wrong asset for this density",
                    state.devicePixelRatio, achieved))
        }
        return notes
    }

    private func restoreLayout(height: Double, scroll: CGPoint) async {
        guard let webView, let window else { return }
        window.setContentSize(CGSize(width: viewport.width, height: height))
        _ = try? await loupeEvaluate(webView, WebScripts.scrollTo(x: scroll.x, y: scroll.y))
        // One short beat so the restored layout is what the next capture sees.
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    private func viewportHeight(_ webView: WKWebView) -> Double { webView.bounds.height }
}
