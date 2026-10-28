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
            return try await handle.stop()
        }
    }

    private static func hold(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }
}
