import Foundation
import LoupeCore

/// The one recording a live session may hold between commands.
///
/// `record start` and `record stop` are separate processes, so something has to
/// own the recorder in between: the session's process does, through this. It is
/// an actor because the recording ends from two sides — the `stop` request and
/// the deadline watchdog — and whichever comes second must find the result
/// rather than a recorder that has already gone.
actor SessionRecorder {

    /// Everything the stop needs that the handle itself does not know.
    private struct Active {
        var handle: any RecordingHandle
        var crop: (region: Frame, scale: Double)?
        var watchdog: Task<Void, Never>?
    }

    private enum State {
        case idle
        case recording(Active)
        case stopping(Task<RecordingResult, any Error>)
        /// Stopped by the deadline, result waiting for the next `stop`.
        case finished(Result<RecordingResult, any Error>)
    }

    private var state: State = .idle

    var isRecording: Bool {
        if case .idle = state { return false }
        return true
    }

    /// Starts filming `driver` into `url`. The region, if any, is cropped at the
    /// source when the driver can, and resolved now otherwise so the caller can
    /// crop afterwards. The recording is stopped on its own at `maxDuration`.
    func start(on driver: any UIDriver, url: URL, options: RecordOptions) async throws {
        guard case .idle = state else {
            throw LoupeError.failed("a recording is already in progress on this session — stop it first")
        }
        guard let recorder = driver as? any RecordingDriver else {
            throw LoupeError.unsupported("\(driver.targetDescription) cannot be recorded")
        }
        var record = options
        var crop: (region: Frame, scale: Double)?
        if let region = options.region, !recorder.cropsRegionAtSource {
            record.region = nil
            crop = try await Loupe.resolveRegion(region, on: driver)
        }
        let handle = try await recorder.startRecording(to: url, options: record)
        let limit = record.maxDuration
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(limit * 1000)))
            guard !Task.isCancelled else { return }
            await self?.expire(limit: limit)
        }
        state = .recording(Active(handle: handle, crop: crop, watchdog: watchdog))
    }

    /// Stops the recording and hands back what was filmed, once.
    func stop() async throws -> RecordingResult {
        switch state {
            case .idle:
                throw LoupeError.failed("no recording is in progress on this session — `record start` first")
            case .recording(let active):
                let task = finalize(active)
                let outcome = await task.result
                state = .idle
                return try outcome.get()
            case .stopping(let task):
                let outcome = await task.result
                state = .idle
                return try outcome.get()
            case .finished(let outcome):
                state = .idle
                return try outcome.get()
        }
    }

    /// Stops a recording that is still running and keeps nothing: for a session
    /// going away, when no one will ask for the result.
    func abandon() async {
        guard case .recording(let active) = state else { return }
        _ = await finalize(active).result
        state = .idle
    }

    private func finalize(_ active: Active) -> Task<RecordingResult, any Error> {
        active.watchdog?.cancel()
        let task = Task {
            var result = try await active.handle.stop()
            if let crop = active.crop {
                result.region = crop.region
                result.scale = crop.scale
            }
            return result
        }
        state = .stopping(task)
        return task
    }

    private func expire(limit: TimeInterval) async {
        guard case .recording(let active) = state else { return }
        let task = finalize(active)
        var outcome = await task.result
        if case .success(var result) = outcome {
            result.notes.append("stopped at the \(Int(limit))s limit before `record stop` was called")
            outcome = .success(result)
        }
        // A `stop` that was waiting on the same task has already taken over.
        if case .stopping = state { state = .finished(outcome) }
    }
}
