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
    var cursorClick: String?
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
        // Both go through the CLI's own step parser rather than a second
        // number-splitter here, so `px:`/`n:`/`screen:` prefixes work identically
        // on both surfaces and cannot drift apart.
        if let click { out.append(try UIAction.parse(step: "click:\(click)")) }
        if let cursorClick { out.append(try UIAction.parse(step: "cursorclick:\(cursorClick)")) }
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

extension LoupeMCPServer {

    /// Resolve `loupe_script`'s two ways of naming a script into one.
    ///
    /// Both spellings earn their place: an agent that just wrote a flow to disk
    /// passes the path, and one composing a check on the spot passes the text.
    /// Supplying neither is the interesting case — an empty script "passes",
    /// so defaulting to one would report success for a call that ran nothing.
    static func scriptSource(source: String?, path: String?) throws -> (text: String, name: String) {
        switch (source, path) {
            case (let source?, nil):
                guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw LoupeError.failed("the script is empty — nothing would run")
                }
                return (source, "<script>")
            case (nil, let path?):
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    throw LoupeError.failed("cannot read a script at \(url.path)")
                }
                return (text, url.lastPathComponent)
            case (nil, nil):
                throw LoupeError.failed("no script given — pass `source` with the script, or `path` to a file")
            case (.some, .some):
                throw LoupeError.failed("pass either `source` or `path`, not both")
        }
    }

    /// A tilde-friendly directory argument.
    static func directory(_ path: String?) -> URL? {
        path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }
}

/// A comparison's numbers plus the files it produced.
///
/// Flattened rather than nested so the numbers and the paths sit at the same
/// level: whoever reads this is deciding "did enough change to be worth posting"
/// and "what do I attach", and those are one thought.
///
/// Both plain captures are here, not just the composite. The composite is the
/// right thing to *look* at — changed regions boxed — and the wrong thing to
/// post as the whole story: a reader following an issue wants to see how it was
/// and how it is, at full size, not a shrunken pair with annotations over them.
struct ComparisonReport: Encodable, Sendable {
    let report: DiffReport
    /// The screenshot taken before the change.
    let beforePath: String
    /// The screenshot taken after it.
    let afterPath: String
    /// The two side by side, with changed regions boxed.
    let compositePath: String

    enum CodingKeys: String, CodingKey { case beforePath, afterPath, compositePath }

    func encode(to encoder: Encoder) throws {
        try report.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(beforePath, forKey: .beforePath)
        try container.encode(afterPath, forKey: .afterPath)
        try container.encode(compositePath, forKey: .compositePath)
    }
}
