import CoreGraphics
import Foundation
import LoupeCore

extension SimDriver {
    // MARK: - Capture

    public func capture(_ options: CaptureOptions) async throws -> Capture {
        let ready = try await ensureReady()
        var notes = ready.notes

        if options.fullPage {
            // Not an unsupported *action*: `fullPage` is documented in LoupeCore as
            // web-only, so ignoring it is the contract. Say so next to the image
            // rather than silently dropping it.
            notes.append("fullPage is web-only; captured the visible screen")
        }

        var png: Data
        if options.settle {
            let result = try await settledScreenshot(ready.device, timeout: options.settleTimeout)
            png = result.png
            if !result.settled {
                notes.append(
                    String(
                        format: "screen was still changing after %.1fs — the capture may contain an "
                            + "in-flight animation", options.settleTimeout))
            }
        } else {
            png = try await rawScreenshot(ready.device)
        }

        let image = try ImageOps.decode(png)
        var pointSize = CGSize(
            width: Double(image.width) / ready.scale,
            height: Double(image.height) / ready.scale)

        if let region = options.region {
            let cropped = try Self.crop(image, to: region, scale: ready.scale)
            png = cropped.png
            pointSize = cropped.pointSize
            if cropped.clamped {
                notes.append(
                    String(
                        format: "requested region was clamped to the %.0f×%.0f pt screen",
                        Double(image.width) / ready.scale, Double(image.height) / ready.scale))
            }
        }

        return Capture(
            png: png,
            pointSize: pointSize,
            scale: ready.scale,
            target: targetDescription,
            notes: notes)
    }

    /// One screenshot, via a temp file.
    ///
    /// Two Xcode 26.4 landmines are handled here. First, `--` then a real path:
    /// passing `-` for stdout is *broken* — simctl prints "Wrote screenshot to:"
    /// and leaves a file literally named `-` in the current directory. Second,
    /// simctl reports success on **stderr** and writes nothing at all to stdout, so
    /// the exit status plus a non-empty file is the only trustworthy signal.
    func rawScreenshot(_ device: SimulatorDevice) async throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-sim-\(UUID().uuidString).png")
        // Unique per call, so several drivers can shoot at once, and always removed.
        defer { try? FileManager.default.removeItem(at: url) }

        let args = ["io", device.udid, "screenshot", "--type=png", "--", url.path]
        let output = try await Simctl.run(args, timeout: 60)
        guard output.succeeded else {
            throw LoupeError.failed(Simctl.failureMessage(args: args, output: output))
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            throw LoupeError.failed(
                "simctl exited 0 but wrote no screenshot for \(device.name) (\(device.udid)). "
                    + "simctl said: \(output.diagnostics)")
        }
        return data
    }

    /// Screenshots ~250 ms apart until two in a row are identical.
    ///
    /// Byte equality is the right test on a simulator: its PNG encoder is
    /// deterministic, so two identical frames really do produce identical files.
    /// Returns the last frame either way — a caller who asked for a screenshot gets
    /// a screenshot, and `settled == false` is surfaced as a capture note rather
    /// than an error, because a blinking caret or a spinner never settles and that
    /// must not make `capture` fail.
    func settledScreenshot(_ device: SimulatorDevice, timeout: Double) async throws
        -> (png: Data, settled: Bool) {
        var previous = try await rawScreenshot(device)
        guard timeout > 0 else { return (previous, false) }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
            let next = try await rawScreenshot(device)
            if next == previous { return (next, true) }
            previous = next
        }
        return (previous, false)
    }

    /// A cropped screenshot and what it took to produce it.
    private struct CroppedScreenshot {
        let png: Data
        let pointSize: CGSize
        /// True when the requested region reached past the screen and was pulled
        /// back to it, which the caller turns into a capture note.
        let clamped: Bool
    }

    /// Crops a decoded screenshot to a region given in *points*.
    ///
    /// `CGImage`'s own coordinate space is top-left origin, which is exactly what
    /// ``Frame`` uses, so no flip is needed here.
    private static func crop(_ image: CGImage, to region: Frame, scale: Double)
        throws -> CroppedScreenshot {
        guard !region.isEmpty else {
            throw LoupeError.failed("capture region has zero width or height")
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let requested = CGRect(
            x: region.x * scale,
            y: region.y * scale,
            width: region.width * scale,
            height: region.height * scale
        ).integral
        let rect = requested.intersection(bounds)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else {
            throw LoupeError.failed(
                String(
                    format: "region %.0f,%.0f %.0f×%.0f pt lies outside the %.0f×%.0f pt screen",
                    region.x, region.y, region.width, region.height,
                    bounds.width / scale, bounds.height / scale))
        }
        guard let cropped = image.cropping(to: rect) else {
            throw LoupeError.failed("could not crop the screenshot to the requested region")
        }
        return CroppedScreenshot(
            png: try ImageOps.encode(cropped),
            pointSize: CGSize(width: rect.width / scale, height: rect.height / scale),
            clamped: rect != requested)
    }

    // MARK: - Describe

    /// The element tree, via the XCUITest bridge.
    ///
    /// `simctl` exposes no accessibility at all, and what Simulator.app forwards
    /// to macOS is flattened past usefulness — a tab bar arrives as a childless
    /// group. So Loupe ships a UI-test runner, installs it on the device and
    /// asks XCUITest, which is the only thing that sees the whole tree. See
    /// ``Bridge``.
    public func describe(_ options: DescribeOptions) async throws -> [UINode] {
        try await describeViaBridge(options)
    }
}
