import Foundation
import LoupeCore

/// How a recording ends.
public enum RecordStop: Sendable {
    /// Record for this long (after any actions have been issued).
    case after(TimeInterval)
    /// Keep recording until an element appears (`A|B`, `!X` as in `wait`).
    case until(nodes: [String], failIf: [String], timeout: TimeInterval)
    /// Run until the task is cancelled, which is how Ctrl-C finalizes the file.
    case cancelled
}

extension Loupe {
    /// Records a target while `actions` run, then stops and finalizes the file.
    ///
    /// Cancelling the calling task is a graceful stop, not a failure: the file is
    /// finalized and returned. Every other exit path stops the recording too, so
    /// no simctl child is left running.
    public static func record(
        _ target: Target,
        to url: URL,
        options: Options = .default,
        record: RecordOptions = .default,
        region: RecordRegion? = nil,
        actions: [UIAction] = [],
        stop: RecordStop
    ) async throws -> RecordingResult {
        // Before withDriver, which would load a page or boot a device for nothing.
        guard target.surface == .sim else {
            throw LoupeError.unsupported(
                "recording works on sim: targets for now — mac: and web: are not implemented yet")
        }
        return try await withDriver(target, options: options) { driver in
            guard let recorder = driver as? any RecordingDriver else {
                throw LoupeError.unsupported("\(driver.targetDescription) cannot be recorded")
            }
            // Resolved before filming, so a bad region fails in a second rather
            // than after the recording it would have thrown away.
            var crop: (region: Frame, scale: Double)?
            if let region {
                crop = try await resolve(region, on: driver)
            }
            let handle = try await recorder.startRecording(to: url, options: record)
            do {
                for action in actions { try await perform(action, on: driver) }
                switch stop {
                    case .after(let seconds):
                        try await hold(min(seconds, record.maxDuration))
                    case .until(let nodes, let failIf, let timeout):
                        try await perform(
                            .waitFor(
                                nodes: nodes, failIf: failIf, gone: false,
                                timeout: min(timeout, record.maxDuration)), on: driver)
                    case .cancelled:
                        try await hold(record.maxDuration)
                }
            } catch is CancellationError {
                // Ctrl-C: fall through to stop and keep what was filmed.
            } catch {
                _ = try? await handle.stop()
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            var result = try await handle.stop()
            result.region = crop?.region
            result.scale = crop?.scale
            return result
        }
    }

    /// Turns a region into points inside the screen, using a screenshot for the
    /// screen's size and scale. An element's frame is read now, at the start;
    /// if the element moves during the recording the crop does not follow it.
    private static func resolve(_ region: RecordRegion, on driver: any UIDriver) async throws
        -> (Frame, Double) {
        let shot = try await driver.capture(CaptureOptions(settle: false))
        let width = shot.pointSize.width
        let height = shot.pointSize.height
        switch region {
            case .frame(let frame):
                _ = try RecordCrop.pixelRect(
                    frame, scale: shot.scale, pixelWidth: Int((width * shot.scale).rounded()),
                    pixelHeight: Int((height * shot.scale).rounded()))
                return (frame, shot.scale)
            case .element(let needle, let padding):
                let node = try await driver.resolve(needle)
                guard let frame = node.frame, !frame.isEmpty else {
                    throw LoupeError.failed("'\(needle)' has no frame to record")
                }
                // Padding can push past the screen edge; that is clamped, since
                // the element itself is what was asked for.
                guard
                    let kept = RecordCrop.clamped(
                        RecordCrop.padded(frame, by: padding), toWidth: width, height: height)
                else {
                    throw LoupeError.failed("'\(needle)' lies outside the screen")
                }
                return (kept, shot.scale)
        }
    }

    private static func hold(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }
}
