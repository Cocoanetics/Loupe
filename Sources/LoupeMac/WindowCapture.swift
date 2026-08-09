import AppKit
import CoreGraphics
import Foundation
import LoupeCore
import ScreenCaptureKit

/// One rendered window image plus the facts needed to interpret it.
///
/// Deliberately made of `Sendable` scalars: the ScreenCaptureKit work runs off
/// the main actor and only this crosses back, so no `SCWindow` ever escapes the
/// capture pipeline.
struct Shot: Sendable {
    var png: Data
    /// Size of the captured content in AppKit points.
    var pointSize: CGSize
    /// Measured pixel/point ratio — `image.width / contentRect.width`, not an
    /// assumed 2.0.
    var scale: Double
    /// The window's rectangle in global screen points, top-left origin. The
    /// caller needs it to translate ``UINode/frame`` coordinates into the image.
    var windowFrame: CGRect
    /// False when the window is minimized, hidden, fully occluded or on another
    /// Space. The pixels are live either way — this is a note, not a warning.
    var onScreen: Bool
    var settled: Bool
    var frames: Int
}

/// Which window to photograph, described the way the accessibility side sees it.
///
/// Every field except `pid` is a *hint*, tried in turn by
/// ``WindowCapture/match(_:target:)`` — the window number comes from an SPI that
/// may one day answer `nil`, and a title can be empty or shared. Grouping them
/// keeps that "best effort, in this order" contract in one place instead of
/// spreading it across an argument list.
struct CaptureTarget: Sendable {
    let pid: pid_t
    let windowNumber: CGWindowID?
    let title: String?
    let frame: Frame?
    /// How to name this window in an error, e.g. `mac:Safari#0 (pid 501)`.
    let appName: String
}

/// Window screenshots via ScreenCaptureKit.
///
/// ScreenCaptureKit is the only option left: `CGWindowListCreateImage` was
/// obsoleted in macOS 15 (it no longer compiles against a current SDK) and it
/// returned nil for exactly the windows this package cares about — the
/// minimized, hidden and occluded ones. SCK renders those live.
enum WindowCapture {
    static let screenRecordingRemedy =
        "System Settings > Privacy & Security > Screen & System Audio Recording, "
        + "then add and enable the binary running Loupe (for a CLI that is the terminal "
        + "or the tool binary itself), and restart it."

    /// Bring up the process's CoreGraphics window-server connection.
    ///
    /// Measured, not theoretical: in a command-line process that has made no
    /// prior CoreGraphics call, `SCContentFilter(desktopIndependentWindow:)`
    /// trips an internal assertion — `CGS_REQUIRE_INIT` in CGInitialization.c —
    /// and **aborts the process with SIGABRT**. Not an error, not a nil: a crash.
    /// A GUI app never sees this because `NSApplication` opens the connection at
    /// startup; a CLI has to ask. One public call is enough, and unlike touching
    /// `NSApplication.shared` it cannot put a Dock icon on the user's screen.
    private static let coreGraphicsReady: Bool = {
        _ = CGMainDisplayID()
        return true
    }()

    /// Capture one window, optionally waiting for its pixels to stop changing.
    ///
    /// The shareable-content query costs ~100 ms, so the settle loop reuses a
    /// single `SCWindow` and only re-runs the (cheap) capture.
    static func capture(
        _ target: CaptureTarget, settle: Bool, settleTimeout: Double
    ) async throws -> Shot {
        // `precondition`, not `_ =`, so the lazy initializer above is guaranteed to
        // run in release builds too rather than being optimized away.
        precondition(coreGraphicsReady)
        guard CGPreflightScreenCaptureAccess() else {
            throw LoupeError.permissionDenied(
                "screen recording is not granted, so no window pixels can be read",
                remedy: screenRecordingRemedy)
        }

        let content: SCShareableContent
        do {
            // onScreenWindowsOnly: false is mandatory. With `true`, minimized and
            // hidden windows are not even enumerated, so a background-first tool
            // would report "no such window" for its most common case.
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
        } catch {
            throw LoupeError.permissionDenied(
                "ScreenCaptureKit could not enumerate windows: \(error.localizedDescription)",
                remedy: screenRecordingRemedy)
        }

        guard let window = match(content.windows, target: target) else {
            let mine = content.windows.filter { $0.owningApplication?.processID == target.pid }
            let listing =
                mine.isEmpty
                ? "ScreenCaptureKit sees no windows owned by pid \(target.pid)"
                : "windows owned by pid \(target.pid): "
                    + mine.map { "#\($0.windowID) '\($0.title ?? "")'" }.joined(separator: ", ")
            throw LoupeError.targetNotFound(
                "no capturable window for \(target.appName) — \(listing)")
        }

        var shot = try await render(window)
        guard settle else { return shot }

        // Two identical PNGs in a row means the window stopped animating. Byte
        // equality is safe here because both frames come from the same encoder.
        let deadline = Date().addingTimeInterval(max(settleTimeout, 0))
        var frames = 1
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
            var next = try await render(window)
            frames += 1
            if next.png == shot.png {
                next.settled = true
                next.frames = frames
                return next
            }
            shot = next
        }
        shot.settled = false
        shot.frames = frames
        return shot
    }

    private static func render(_ window: SCWindow) async throws -> Shot {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let contentRect = filter.contentRect
        let nominalScale = Double(filter.pointPixelScale)

        let configuration = SCStreamConfiguration()
        configuration.width = Int((contentRect.width * nominalScale).rounded())
        configuration.height = Int((contentRect.height * nominalScale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        // The drop shadow is not part of the window and would add transparent
        // margins that move whenever the window moves — pure diff noise.
        configuration.ignoreShadowsSingleWindow = true
        configuration.scalesToFit = false

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
        } catch {
            // ScreenCaptureKit reports a locked screen as "Failed to start stream
            // due to audio/video capture failure", which tells the caller nothing.
            // A locked Mac is a completely ordinary state for an unattended agent to
            // meet, so name it.
            if isScreenLocked() {
                throw LoupeError.failed(
                    """
                    cannot capture while the screen is locked — macOS stops all screen \
                    capture until someone unlocks it.
                      Accessibility still works, so `describe` and actions like press and \
                    setValue continue to run; only images are unavailable.
                      Unlock the Mac and retry, or use a sim: or web: target, neither of \
                    which depends on the display being unlocked.
                    """)
            }
            throw LoupeError.failed(
                "ScreenCaptureKit failed to capture window #\(window.windowID): "
                    + error.localizedDescription)
        }

        let scale = contentRect.width > 0 ? Double(image.width) / contentRect.width : nominalScale
        return Shot(
            png: try ImageOps.encode(image),
            pointSize: contentRect.size,
            scale: scale > 0 ? scale : 1,
            windowFrame: window.frame,
            onScreen: window.isOnScreen,
            settled: true,
            frames: 1)
    }

    /// Pair an accessibility window with its ScreenCaptureKit twin.
    ///
    /// Best case the window number matches exactly. The fallbacks exist because
    /// the window-number lookup is an SPI: frame, then title, then the largest
    /// normal-layer window of the process — in that order, because a frame is
    /// unique in practice while several windows can share a title.
    private static func match(_ windows: [SCWindow], target: CaptureTarget) -> SCWindow? {
        if let windowNumber = target.windowNumber,
            let exact = windows.first(where: { $0.windowID == windowNumber }) {
            return exact
        }
        let mine = windows.filter {
            $0.owningApplication?.processID == target.pid && $0.frame.width > 1 && $0.frame.height > 1
        }
        if let frame = target.frame {
            let tolerance = 2.0
            if let byFrame = mine.first(where: {
                abs($0.frame.origin.x - frame.x) < tolerance
                    && abs($0.frame.origin.y - frame.y) < tolerance
                    && abs($0.frame.width - frame.width) < tolerance
                    && abs($0.frame.height - frame.height) < tolerance
            }) {
                return byFrame
            }
        }
        if let title = target.title, !title.isEmpty,
            let byTitle = mine.first(where: { $0.title == title }) {
            return byTitle
        }
        return mine.filter { $0.windowLayer == 0 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
}

/// Whether the login window is covering the session.
///
/// Cheap enough to check only on the failure path, and it turns an opaque
/// ScreenCaptureKit error into something a caller can act on.
func isScreenLocked() -> Bool {
    guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (info["CGSSessionScreenIsLocked"] as? Int) == 1
}

extension WindowCapture {
    /// Backing scale of the display a window sits on.
    ///
    /// Read from the actual display rather than assumed to be 2: a window dragged
    /// to a non-Retina external monitor has a scale of 1, and getting this wrong
    /// puts every pixel-space click at double or half the intended position.
    static func backingScale(forWindowAt frame: Frame) -> Double? {
        let center = CGPoint(x: frame.centerX, y: frame.centerY)
        let screen =
            NSScreen.screens.first { screen in
                // AppKit screen frames are bottom-left origin; window frames are
                // top-left, so flip before testing containment.
                let height = NSScreen.screens.first?.frame.maxY ?? 0
                let flipped = CGPoint(x: center.x, y: height - center.y)
                return screen.frame.contains(flipped)
            } ?? NSScreen.main
        return screen.map { Double($0.backingScaleFactor) }
    }
}
