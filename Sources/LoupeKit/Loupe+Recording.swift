import Foundation
import LoupeCore
import LoupeSim

/// How a recording ends.
public enum RecordStop: Sendable {
    /// Record for this long (after any actions have been issued).
    case after(TimeInterval)
    /// Keep recording until an element appears (`A|B`, `!X` as in `wait`).
    case until(nodes: [String], failIf: [String], timeout: TimeInterval)
    /// Run until the task is cancelled, which is how Ctrl-C finalizes the file.
    case cancelled

    /// `--until` as `wait` spells it: `A|B` for alternatives, `!X` for a failure.
    public static func until(_ spec: String, timeout: TimeInterval) -> RecordStop {
        var nodes: [String] = []
        var failures: [String] = []
        for candidate in spec.split(separator: "|") {
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("!") {
                failures.append(String(trimmed.dropFirst()))
            } else {
                nodes.append(trimmed)
            }
        }
        return .until(nodes: nodes, failIf: failures, timeout: timeout)
    }
}

extension Loupe {
    /// Records a target while `actions` run, then stops and finalizes the file.
    ///
    /// Cancelling the calling task is a graceful stop, not a failure: the file is
    /// finalized and returned. Every other exit path stops the recording too, so
    /// no simctl child is left running.
    ///
    /// - Parameter pinStatusBar: on a simulator, show Apple's 9:41 status bar
    ///   while filming and put the live one back afterwards — what an App Store
    ///   preview wants. Ignored elsewhere.
    public static func record(
        _ target: Target,
        to url: URL,
        options: Options = .default,
        record: RecordOptions = .default,
        region: RecordRegion? = nil,
        actions: [UIAction] = [],
        stop: RecordStop,
        pinStatusBar: Bool = false
    ) async throws -> RecordingResult {
        // Before withDriver, which would load a page for nothing.
        guard target.surface != .web else {
            throw LoupeError.unsupported(
                "recording works on sim:, mac: and @session targets — web: is not implemented yet")
        }
        return try await withDriver(target, options: options) { driver in
            let session = Session(url: url, record: record, region: region, actions: actions, stop: stop)
            guard pinStatusBar, let sim = driver as? SimDriver, try await sim.isStatusBarOverridden() == false
            else {
                return try await recordSession(on: driver, session)
            }
            try await sim.setStatusBar()
            do {
                let result = try await recordSession(on: driver, session)
                try? await sim.clearStatusBar()
                return result
            } catch {
                try? await sim.clearStatusBar()
                throw error
            }
        }
    }

    struct Session {
        var url: URL
        var record: RecordOptions
        var region: RecordRegion?
        var actions: [UIAction]
        var stop: RecordStop
    }

    /// The recording itself, on a driver already prepared. `record.maxDuration`
    /// is one deadline from the moment filming starts: the actions run under it,
    /// and the closing wait gets only what is left.
    static func recordSession(on driver: any UIDriver, _ session: Session) async throws
        -> RecordingResult {
        let (url, actions, stop) = (session.url, session.actions, session.stop)
        var recordOptions = session.record
        var region = session.region
        guard let recorder = driver as? any RecordingDriver else {
            throw LoupeError.unsupported("\(driver.targetDescription) cannot be recorded")
        }
        // A driver that crops while filming gets the region itself and resolves it
        // against its own coordinate space (a window, for mac:).
        if recorder.cropsRegionAtSource {
            recordOptions.region = region
            region = nil
        }
        let record = recordOptions
        // Resolved before filming, so a bad region fails in a second rather
        // than after the recording it would have thrown away.
        var crop: (region: Frame, scale: Double)?
        if let region {
            crop = try await resolveRegion(region, on: driver)
        }
        let handle = try await recorder.startRecording(to: url, options: record)
        do {
            try await film(actions, then: stop, on: driver, limit: record.maxDuration)
        } catch is CancellationError {
            // Ctrl-C: fall through to stop and keep what was filmed.
        } catch {
            _ = try? await handle.stop()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        var result = try await handle.stop()
        // A session that could not crop at its source hands the region back in
        // the result; only a crop resolved here replaces it.
        if let crop {
            result.region = crop.region
            result.scale = crop.scale
        }
        return result
    }

    /// What happens while the recorder runs: the actions, then the closing wait,
    /// all under one deadline counted from now.
    private static func film(
        _ actions: [UIAction], then stop: RecordStop, on driver: any UIDriver, limit: TimeInterval
    ) async throws {
        let startedAt = Date()
        let remaining = { max(0, limit - Date().timeIntervalSince(startedAt)) }
        if !actions.isEmpty {
            try await Deadline.run(
                seconds: remaining(), "the actions, within the \(Int(limit))s recording limit"
            ) {
                for action in actions { try await perform(action, on: driver) }
            }
        }
        switch stop {
            case .after(let seconds):
                try await hold(min(seconds, remaining()))
            case .until(let nodes, let failIf, let timeout):
                try await perform(
                    .waitFor(nodes: nodes, failIf: failIf, gone: false, timeout: min(timeout, remaining())),
                    on: driver)
            case .cancelled:
                try await hold(remaining())
        }
    }

    /// Turns a region into points inside the screen, using a screenshot for the
    /// screen's size and scale. An element's frame is read now, at the start;
    /// if the element moves during the recording the crop does not follow it.
    static func resolveRegion(_ region: RecordRegion, on driver: any UIDriver) async throws
        -> (region: Frame, scale: Double) {
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
