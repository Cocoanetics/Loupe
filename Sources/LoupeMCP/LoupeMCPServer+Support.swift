import Darwin
import Foundation
import Logging
import LoupeKit
import SwiftMCP

// The pieces `LoupeMCPServer` needs but that are not tools themselves. They live
// apart so the actor's own body stays a readable list of verbs.

extension LoupeMCPServer {

    // MARK: - Argument shapes

    /// Surface options from the loose strings a tool call carries. A mistyped
    /// `WxH` viewport falls back to the default rather than failing the call: it
    /// only affects web targets, and an agent that gets it wrong while capturing a
    /// Mac window should still get its screenshot.
    func options(viewport: String?, scale: Double?, profile: String?) -> Loupe.Options {
        var size = CGSize(width: 1280, height: 900)
        if let viewport {
            let parts = viewport.lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { size = CGSize(width: parts[0], height: parts[1]) }
        }
        return Loupe.Options(viewport: size, scale: scale ?? 2.0, profile: profile)
    }

    /// A malformed `region` is dropped rather than rejected, for the same reason
    /// as a malformed viewport: an uncropped screenshot is still a useful answer.
    func captureOptions(fullPage: Bool?, settle: Bool?, region: String?) -> CaptureOptions {
        var frame: Frame?
        if let region {
            let numbers = region.split(separator: ",").compactMap {
                Double($0.trimmingCharacters(in: .whitespaces))
            }
            if numbers.count == 4 {
                frame = Frame(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            }
        }
        return CaptureOptions(
            region: frame, fullPage: fullPage ?? false, settle: settle ?? true, settleTimeout: 3.0)
    }

    // MARK: - Encoding

    /// Structured results travel as text, with sorted keys so an agent comparing
    /// two calls sees only the differences that are real.
    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LoupeError.failed("encoded JSON was not valid UTF-8")
        }
        return text
    }

    // MARK: - Live sessions

    /// Spawn a session's own process and wait for it to register itself, so a
    /// failure to start is reported rather than showing up later as a target that
    /// does not exist.
    func openSession(
        target: String, name: String, viewport: String?, profile: String?
    ) async throws -> String {
        let parsed = try Target.parse(target)
        guard parsed.surface != .live else {
            throw LoupeError.failed("cannot open a session on another session")
        }
        if let existing = try? LiveSession.load(name) {
            throw LoupeError.failed(
                "session '\(name)' is already open on \(existing.target) — close it first, "
                    + "or use @\(name) as your target")
        }
        var args = ["session", "serve", parsed.description, "--as", name]
        if let viewport { args += ["--viewport", viewport] }
        if let profile { args += ["--profile", profile] }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: Self.executablePath())
        child.arguments = args
        // A pipe nobody drains deadlocks the child once WebKit fills it.
        let logURL = LiveSession.registryRoot.appendingPathComponent("\(name).log")
        try FileManager.default.createDirectory(
            at: LiveSession.registryRoot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        child.standardOutput = handle
        child.standardError = handle
        try child.run()

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let live = try? LiveSession.load(name) {
                return "Session open. Use target \"@\(name)\" for \(live.target) in later calls, "
                    + "then loupe_session_close when finished."
            }
            if !child.isRunning {
                let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                throw LoupeError.failed("session failed to start: \(log)")
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        child.terminate()
        LiveSession.remove(name)
        throw LoupeError.timeout("session '\(name)' did not come up within 30s")
    }

    /// Path to this binary, so a session's child process is the same signed
    /// executable and inherits the same TCC grants.
    static func executablePath() -> String {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return "loupe" }
        // Truncate at the NUL before decoding: the buffer is C-sized, so the tail
        // after the terminator is padding rather than part of the path.
        let bytes = Data(buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) })
        return String(bytes: bytes, encoding: .utf8) ?? "loupe"
    }

    // MARK: - Serving

    /// Serve over stdio, which is how ACP/acpx agents and Claude Code launch it.
    public static func serveOverStdio() async throws {
        let server = LoupeMCPServer()
        // stdio carries the protocol itself, so logging must go to stderr or it
        // corrupts the stream.
        var logger = Logger(label: "dev.cocoanetics.loupe.mcp")
        logger.logLevel = .warning
        try await server.serve(over: [StdioTransport()], logger: logger)
    }
}

/// The optional action arguments the acting tools take, gathered into one value
/// so the conversion has a single parameter instead of nine.
struct ActionRequest {
    var press: String?
    var setValue: String?
    var click: String?
    var type: String?
    var key: String?
    var scroll: String?
    var open: String?
    var launch: String?
    var eval: String?

    /// The steps in the order a form actually wants them: get to the right place,
    /// activate, put values in, then point and type. The same ordering the CLI
    /// uses, and for the same reason — pressing before setting submits an empty
    /// form.
    func actions() throws -> [UIAction] {
        var out: [UIAction] = []
        out += try arrivalActions()
        out += try elementActions()
        out += try inputActions()
        if let eval { out.append(.evaluate(eval)) }
        return out
    }

    /// Getting to the screen the rest of the steps expect.
    private func arrivalActions() throws -> [UIAction] {
        var out: [UIAction] = []
        if let launch { out.append(.launch(launch)) }
        if let open { out.append(.navigate(try EnvironmentInterpolation.expand(open))) }
        return out
    }

    /// Steps that name an element rather than a coordinate.
    private func elementActions() throws -> [UIAction] {
        var out: [UIAction] = []
        if let press { out.append(.press(node: press)) }
        if let setValue, let equals = setValue.firstIndex(of: "=") {
            // Must throw rather than fall back to the literal: an unresolved
            // {{NAME}} typed into a password field fails as "wrong credentials",
            // and the missing variable is the last thing anyone suspects.
            out.append(
                .setValue(
                    node: String(setValue[setValue.startIndex..<equals]),
                    value: try EnvironmentInterpolation.expand(
                        String(setValue[setValue.index(after: equals)...]))))
        }
        return out
    }

    /// Pointer and keyboard steps, which act on whatever is under the point or
    /// has focus.
    private func inputActions() throws -> [UIAction] {
        var out: [UIAction] = []
        if let point = Self.pair(click) {
            out.append(.click(x: point.first, y: point.second, space: .windowPoints, viaCursor: false))
        }
        if let type { out.append(.type(try EnvironmentInterpolation.expand(type))) }
        if let key { out.append(.key(key)) }
        if let delta = Self.pair(scroll) {
            out.append(.scroll(dx: delta.first, dy: delta.second))
        }
        return out
    }

    /// Two comma-separated numbers, or nil — a malformed pair is dropped rather
    /// than failing the whole call, matching what the CLI does with the same spec.
    private static func pair(_ spec: String?) -> (first: Double, second: Double)? {
        guard let spec else { return nil }
        let numbers = spec.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard numbers.count == 2 else { return nil }
        return (numbers[0], numbers[1])
    }
}
