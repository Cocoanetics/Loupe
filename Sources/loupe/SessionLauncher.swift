import Foundation
import LoupeKit

/// Starts a live session's process.
///
/// Its own type rather than a method on the `session open` command, because two
/// commands need it — `session open` and `use --session` — and an
/// ArgumentParser command cannot be constructed and run programmatically: its
/// property wrappers are only populated by parsing, so a directly-initialized
/// one silently does nothing.
enum SessionLauncher {

    /// Everything needed to start one session.
    ///
    /// A struct rather than a long parameter list: these travel together from two
    /// different commands, and half of them are optional knobs that read as noise
    /// at each call site.
    struct Request {
        var target: Target
        var name: String
        var viewport = "1280x900"
        var scale = 2.0
        var profile: String?
        var idleTimeout = 900.0
        /// Also make it the current target, so following commands can omit it.
        var remember = true
    }

    /// Open a session and wait until it answers.
    static func open(_ request: Request) async throws {
        let target = request.target
        let name = request.name
        let viewport = request.viewport
        let profile = request.profile
        guard target.surface != .live else {
            throw LoupeError.failed("cannot open a session on another session")
        }
        if let existing = try? LiveSession.load(name) {
            throw LoupeError.failed(
                "session '\(name)' is already open on \(existing.target) — close it first")
        }

        let logURL = LiveSession.registryRoot.appendingPathComponent("\(name).log")
        let child = try spawn(request, logURL: logURL)
        try await waitForStartup(of: child, request: request, logURL: logURL)
    }

    /// Re-exec ourselves detached: the child owns the driver, so the session
    /// outlives the command that opened it.
    private static func spawn(_ request: Request, logURL: URL) throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        var args = [
            "session", "serve", request.target.description, "--as", request.name,
            "--viewport", request.viewport, "--scale", "\(request.scale)",
            "--idle-timeout", "\(request.idleTimeout)"
        ]
        if let profile = request.profile { args += ["--profile", profile] }
        child.arguments = args
        // Log to a file rather than a Pipe: nothing here drains a pipe while
        // waiting, so once WebKit fills the 64 KB buffer the child blocks on
        // write and never finishes starting.
        try FileManager.default.createDirectory(
            at: LiveSession.registryRoot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        child.standardError = logHandle
        child.standardOutput = logHandle
        try child.run()
        return child
    }

    /// Block only long enough to confirm the child registered itself, so the
    /// caller gets a real error instead of a session that silently failed to
    /// start.
    private static func waitForStartup(of child: Process, request: Request, logURL: URL)
        async throws {
        let name = request.name
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let live = try? LiveSession.load(name) {
                if request.remember {
                    try CurrentTarget.save(
                        CurrentTarget(
                            target: "@\(name)", viewport: request.viewport, profile: request.profile))
                }
                print("@\(name)")
                FileHandle.standardError.write(
                    Data("session '\(name)' open on \(live.target) (pid \(live.pid))\n".utf8))
                return
            }
            if !child.isRunning {
                let err = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                let detail = err.isEmpty ? "(no output — see \(logURL.path))" : err
                throw LoupeError.failed("session failed to start:\n\(detail)")
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        child.terminate()
        LiveSession.remove(name)
        let err = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        throw LoupeError.timeout(
            "session '\(name)' did not come up within 30s. Log:\n\(err.isEmpty ? "(empty)" : err)")
    }
}
