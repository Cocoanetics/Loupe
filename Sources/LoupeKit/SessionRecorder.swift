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
        /// `claimed` when a `stop` is waiting for it, so the file is spoken for.
        case stopping(Task<RecordingResult, any Error>, claimed: Bool)
        /// Stopped by the deadline, result waiting for the next `stop`.
        case finished(Result<RecordingResult, any Error>)
    }

    private var state: State = .idle
    /// The file being written, until a `stop` hands it to its caller.
    private var scratch: URL?

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
        scratch = url
    }

    /// Stops the recording and hands back what was filmed, once.
    func stop() async throws -> RecordingResult {
        switch state {
            case .idle:
                throw LoupeError.failed("no recording is in progress on this session — `record start` first")
            case .recording(let active):
                let task = finalize(active, claimed: true)
                return try await handOver(task.result)
            case .stopping(let task, _):
                state = .stopping(task, claimed: true)
                return try await handOver(task.result)
            case .finished(let outcome):
                return try handOver(outcome)
        }
    }

    /// The file now belongs to the caller: forget it here.
    private func handOver(_ outcome: Result<RecordingResult, any Error>) throws -> RecordingResult {
        state = .idle
        scratch = nil
        return try outcome.get()
    }

    /// Ends whatever is in flight and keeps nothing: for a session going away,
    /// when no one will ask for the result. Waits for a stop that is already
    /// under way, so the session does not exit mid-write, and deletes the file
    /// unless a `stop` is about to hand it to its caller.
    func abandon() async {
        switch state {
            case .idle:
                return
            case .recording(let active):
                _ = await finalize(active, claimed: false).result
            case .stopping(let task, _):
                _ = await task.result
            case .finished:
                break
        }
        // A `stop` that was waiting on the same task has taken the file.
        guard case .stopping(_, claimed: true) = state else {
            state = .idle
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
            scratch = nil
            return
        }
    }

    private func finalize(_ active: Active, claimed: Bool) -> Task<RecordingResult, any Error> {
        active.watchdog?.cancel()
        let task = Task {
            var result = try await active.handle.stop()
            if let crop = active.crop {
                result.region = crop.region
                result.scale = crop.scale
            }
            return result
        }
        state = .stopping(task, claimed: claimed)
        return task
    }

    private func expire(limit: TimeInterval) async {
        guard case .recording(let active) = state else { return }
        let task = finalize(active, claimed: false)
        var outcome = await task.result
        if case .success(var result) = outcome {
            result.notes.append("stopped at the \(Int(limit))s limit before `record stop` was called")
            outcome = .success(result)
        }
        // A `stop` that was waiting on the same task has already taken over.
        if case .stopping(_, claimed: false) = state { state = .finished(outcome) }
    }
}
