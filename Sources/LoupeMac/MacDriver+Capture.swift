import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LoupeCore

extension MacDriver {
    // MARK: - Capture

    /// Screenshot the resolved window.
    ///
    /// Works while the window is behind others, minimized, hidden or on another
    /// Space; ScreenCaptureKit re-renders it rather than reading the screen.
    /// `options.fullPage` has no meaning for a macOS window and is ignored (with
    /// a note) rather than treated as an error.
    public func capture(_ options: CaptureOptions) async throws -> Capture {
        try requireResolved()
        try ensureResolved()
        guard let window = windowElement, let application = runningApplication else {
            throw LoupeError.targetNotFound(appLocator)
        }
        let frontmostBefore = NSWorkspace.shared.frontmostApplication

        let shot = try await WindowCapture.capture(
            captureTarget(for: window, of: application),
            settle: options.settle,
            settleTimeout: options.settleTimeout)

        var notes = captureNotes(
            for: shot, options: options, application: application, window: window,
            frontmostBefore: frontmostBefore)

        var png = shot.png
        var pointSize = shot.pointSize
        if let region = options.region {
            (png, pointSize) = try crop(shot, to: region, notes: &notes)
        }

        return Capture(
            png: png,
            pointSize: pointSize,
            scale: shot.scale,
            target: resolvedDescription,
            notes: notes)
    }

    /// Everything ScreenCaptureKit needs to find this exact window again.
    func captureTarget(for window: AXUIElement, of application: NSRunningApplication)
        -> CaptureTarget {
        CaptureTarget(
            pid: application.processIdentifier,
            windowNumber: AXAPI.windowNumber(window),
            title: AXAPI.string(window, kAXTitleAttribute),
            frame: AXAPI.frame(window),
            appName: resolvedDescription)
    }

    /// The facts a caller needs to interpret the image it just got.
    ///
    /// All of these are notes rather than errors on purpose: a minimized or
    /// hidden window still yields live pixels, and refusing to capture it would
    /// throw away the driver's main advantage.
    private func captureNotes(
        for shot: Shot,
        options: CaptureOptions,
        application: NSRunningApplication,
        window: AXUIElement,
        frontmostBefore: NSRunningApplication?
    ) -> [String] {
        var notes: [String] = [
            String(
                format: "window frame in screen points: x=%.0f y=%.0f w=%.0f h=%.0f",
                shot.windowFrame.origin.x, shot.windowFrame.origin.y,
                shot.windowFrame.width, shot.windowFrame.height)
        ]
        if options.fullPage {
            notes.append("fullPage is a web-only option and was ignored for this macOS window")
        }
        if !shot.onScreen {
            notes.append(
                "window is not on screen (minimized, hidden, fully occluded or on another Space) "
                    + "— ScreenCaptureKit still rendered its live pixels")
        }
        if application.isHidden { notes.append("application is hidden") }
        if AXAPI.bool(window, kAXMinimizedAttribute) == true { notes.append("window is minimized") }
        if !shot.settled {
            notes.append(
                String(
                    format: "content was still changing after %.1fs (%d frames compared)",
                    options.settleTimeout, shot.frames))
        }
        if let front = frontmostBefore, front.processIdentifier != application.processIdentifier {
            notes.append(
                "captured from the background — frontmost app was \(front.localizedName ?? "?")")
        }
        return notes
    }

    /// Crop to a region given in global screen points.
    private func crop(_ shot: Shot, to region: Frame, notes: inout [String]) throws -> (
        Data, CGSize
    ) {
        guard !region.isEmpty else {
            throw LoupeError.failed("capture region has zero width or height")
        }
        let image = try ImageOps.decode(shot.png)
        let requested = CGRect(
            x: (region.x - shot.windowFrame.origin.x) * shot.scale,
            y: (region.y - shot.windowFrame.origin.y) * shot.scale,
            width: region.width * shot.scale,
            height: region.height * shot.scale)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = requested.intersection(bounds).integral

        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1,
            let cropped = image.cropping(to: clipped)
        else {
            throw LoupeError.failed(
                String(
                    format:
                        "region x=%.0f y=%.0f w=%.0f h=%.0f does not overlap the window, whose screen "
                        + "frame is x=%.0f y=%.0f w=%.0f h=%.0f — region coordinates are global screen "
                        + "points (the same space as UINode.frame), not window-relative ones",
                    region.x, region.y, region.width, region.height,
                    shot.windowFrame.origin.x, shot.windowFrame.origin.y,
                    shot.windowFrame.width, shot.windowFrame.height))
        }
        if clipped != requested.integral {
            notes.append("region reached past the window edge and was clipped to it")
        }
        return (
            try ImageOps.encode(cropped),
            CGSize(
                width: Double(cropped.width) / shot.scale, height: Double(cropped.height) / shot.scale)
        )
    }

    /// Wait for the window to stop changing, so a before/after pair is not just
    /// two frames of the same animation.
    func settle(timeout: Double) async throws -> ActionResult {
        try ensureResolved()
        guard let window = windowElement, let application = runningApplication else {
            throw LoupeError.targetNotFound(appLocator)
        }
        let start = Date()
        let shot = try await WindowCapture.capture(
            captureTarget(for: window, of: application),
            settle: true,
            settleTimeout: timeout)
        let elapsed = Date().timeIntervalSince(start)
        if shot.settled {
            return ActionResult(
                message: String(
                    format: "window stopped changing after %.1fs (%d frames)", elapsed, shot.frames))
        }
        return ActionResult(
            ok: false,
            message: String(
                format: "window was still changing after %.1fs (%d frames) — a before/after diff "
                    + "taken now will contain animation noise", elapsed, shot.frames))
    }
}
