import Foundation
import LoupeCore

extension SimDriver: RecordingDriver {
    public func startRecording(to url: URL, options: RecordOptions) async throws
        -> any RecordingHandle {
        let ready = try await ensureReady()
        try? FileManager.default.removeItem(at: url)
        // Pinned here, in the driver, so every way of recording — one-shot,
        // MCP, or a session's `record start` — shows the same status bar and
        // puts the live one back when the handle stops. An override someone
        // set on purpose is left alone.
        let pin = options.pinStatusBar ? await !hasStatusBarOverride(ready.device) : false
        if pin { try await setStatusBar() }
        do {
            return try await SimRecording.start(device: ready.device, url: url, pinnedStatusBar: pin) { [weak self] in
                guard pin else { return }
                _ = try? await self?.clearStatusBar()
            }
        } catch {
            if pin { _ = try? await clearStatusBar() }
            throw error
        }
    }
}

/// One `simctl io recordVideo` child process.
///
/// simctl finalizes the movie only when it is interrupted: SIGINT writes the
/// moov atom, anything harsher leaves a file that does not play. So the stop path
/// is SIGINT, a bounded wait for exit, and a check that the file really is there
/// — exit status alone is not trusted, the same as for screenshots.
final class SimRecording: RecordingHandle, @unchecked Sendable {
    private let process: Process
    private let url: URL
    private let startedAt = Date()
    private let stderr = Locked("")
    private let exited = DispatchSemaphore(value: 0)
    private let stopped = Locked(false)
    private let deviceName: String
    /// Runs once the child has exited, however the stop went: undoes what
    /// `startRecording` set up for the film, such as a pinned status bar.
    private let cleanup: @Sendable () async -> Void
    private let pinnedStatusBar: Bool

    private static let queue = DispatchQueue(
        label: "com.cocoanetics.loupe.simctl.record", qos: .userInitiated, attributes: .concurrent)

    /// Longest simctl gets to write the file after SIGINT.
    private static let finalizeTimeout: Double = 30

    private init(
        process: Process, url: URL, deviceName: String, pinned: Bool, cleanup: @escaping @Sendable () async -> Void
    ) {
        self.process = process
        self.url = url
        self.deviceName = deviceName
        self.pinnedStatusBar = pinned
        self.cleanup = cleanup
    }

    /// - Parameter cleanup: run after the recording ends, whichever way. With a
    ///   pinned status bar the result also says so.
    static func start(
        device: SimulatorDevice, url: URL, pinnedStatusBar: Bool = false,
        cleanup: @escaping @Sendable () async -> Void = {}
    ) async throws -> SimRecording {
        let args = ["simctl", "io", device.udid, "recordVideo", "--codec=h264", "--force", "--", url.path]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = args
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let recording = SimRecording(
            process: process, url: url, deviceName: device.name, pinned: pinnedStatusBar, cleanup: cleanup)
        process.terminationHandler = { [exited = recording.exited] _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw LoupeError.failed(
                "could not run `/usr/bin/xcrun simctl`: \(error.localizedDescription)\n"
                    + "  Fix: install Xcode command line tools and check `xcode-select -p`.")
        }
        let errHandle = errPipe.fileHandleForReading
        let captured = recording.stderr
        queue.async {
            // Line by line, so "Recording started" is seen while simctl keeps running.
            while case let chunk = errHandle.availableData, !chunk.isEmpty {
                captured.value += String(bytes: chunk, encoding: .utf8) ?? ""
            }
        }

        // Frames before simctl says it is recording are lost, and an early
        // SIGINT would finalize nothing. Wait for the announcement.
        // Any way out of the wait other than success — a timeout, simctl dying,
        // the task being cancelled — must not leave the child recording.
        do {
            try await recording.waitForStart(timeout: 20, deviceName: device.name)
        } catch {
            recording.kill()
            throw error
        }
        return recording
    }

    private func waitForStart(timeout: Double, deviceName: String) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !stderr.value.contains("Recording started") {
            if !process.isRunning {
                throw LoupeError.failed("simctl stopped before recording \(deviceName): \(diagnostics)")
            }
            if Date() > deadline {
                throw LoupeError.timeout(
                    "simctl did not start recording \(deviceName) within \(Int(timeout))s: \(diagnostics)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private var diagnostics: String {
        let text = stderr.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "(no output)" : text
    }

    func stop() async throws -> RecordingResult {
        let first = stopped.value == false
        stopped.value = true
        guard first else { throw LoupeError.failed("this recording was already stopped") }
        // The cleanup runs after the child is gone, success or not, and before
        // the caller gets control back: a status bar restored a moment after the
        // command exits is one nobody can rely on.
        let outcome: Result<RecordingResult, any Error>
        do {
            outcome = .success(try await finish())
        } catch {
            outcome = .failure(error)
        }
        await cleanup()
        return try outcome.get()
    }

    private func finish() async throws -> RecordingResult {
        let duration = Date().timeIntervalSince(startedAt)
        if process.isRunning { Foundation.kill(process.processIdentifier, SIGINT) }
        let finished = await withCheckedContinuation { continuation in
            Self.queue.async {
                continuation.resume(
                    returning: self.exited.wait(timeout: .now() + Self.finalizeTimeout) == .success)
            }
        }
        guard finished else {
            kill()
            throw LoupeError.timeout(
                "simctl did not finish writing \(url.lastPathComponent) within "
                    + "\(Int(Self.finalizeTimeout))s after being interrupted; the file is not trustworthy")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 0 else {
            throw LoupeError.failed(
                "simctl exited but wrote no recording of \(deviceName). simctl said: \(diagnostics)")
        }
        return RecordingResult(
            url: url, duration: duration, bytes: size,
            notes: pinnedStatusBar ? [RecordOptions.statusBarPinnedNote] : [])
    }

    /// Last resort: the child must not outlive its recording.
    private func kill() {
        guard process.isRunning else { return }
        process.terminate()
        if exited.wait(timeout: .now() + 3) == .timedOut {
            Foundation.kill(process.processIdentifier, SIGKILL)
        }
    }
}
