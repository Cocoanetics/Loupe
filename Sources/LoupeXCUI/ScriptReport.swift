import Foundation
import LoupeKit

/// Everything one script run produced, in a shape both the CLI and the MCP tool
/// can present.
///
/// `ScriptRunner.Outcome` is the runner's own vocabulary — an enum plus loose
/// arrays. This is the reportable form: flat, `Codable`, and carrying the two
/// things a caller who wasn't watching needs, the script's printed output and
/// the rendered failures. The CLI prints ``text``; the MCP tool hands back the
/// JSON. One run, two presentations, no second implementation.
public struct ScriptReport: Codable, Sendable {

    public enum Status: String, Codable, Sendable {
        case passed
        case skipped
        case failed
    }

    public var status: Status
    /// The script's name, as it appears in failure locations.
    public var script: String
    public var duration: TimeInterval
    /// Why the run was skipped. Only set for `.skipped`.
    public var reason: String?
    /// The failure, when it wasn't an expectation — a thrown driver error, a
    /// nonzero `exit()`, a timeout. Only set for `.failed`.
    public var error: String?
    /// Every expectation that failed, each already rendered with the line that
    /// recorded it and a caret under the failing call.
    public var issues: [String]
    /// What the script printed. The point of scripting is often to read a value
    /// back, so this is the payload, not a diagnostic.
    public var output: String
    /// Screenshots the script attached, as file paths.
    public var attachments: [String]

    public var isSuccess: Bool { status != .failed }

    /// The human-facing rendering — what the CLI prints and what a person reads
    /// in a log. Excludes ``output``, which the CLI has already streamed.
    public var text: String {
        let seconds = String(format: "%.1fs", duration)
        switch status {
            case .passed:
                return "\(script) passed in \(seconds)\n"
            case .skipped:
                let why = (reason?.isEmpty == false) ? ": \(reason!)" : ""
                return "\(script) skipped after \(seconds)\(why)\n"
            case .failed:
                var report = "\(script) FAILED after \(seconds)\n"
                guard !issues.isEmpty else {
                    return report + "\(error ?? "failed")\n"
                }
                // List every recorded expectation rather than only a summary.
                // Reporting them together is the entire point of letting a
                // failed expectation continue.
                for issue in issues {
                    // An issue may be a whole rendered source listing, so the
                    // bullet marks its first line and the rest indents under it.
                    let lines = issue.split(separator: "\n", omittingEmptySubsequences: false)
                    report += "  ✗ \(lines.first ?? "")\n"
                    for line in lines.dropFirst() where !line.isEmpty {
                        report += "    \(line)\n"
                    }
                }
                return report
        }
    }
}

/// What to run, and where to point it.
///
/// Exists so the CLI's flags and the MCP tool's parameters converge on one
/// value before anything runs — the alternative is two call sites that each
/// decide what a missing target or an absent screenshot directory means, and
/// drift the first time one of them gains an option.
public struct ScriptRequest: Sendable {
    public var source: String
    public var fileName: String
    /// What a bare `XCUIApplication()` resolves to.
    public var defaultTarget: Target?
    public var options: Loupe.Options
    /// Where `screenshot().attach(named:)` images are written.
    public var attachmentDirectory: URL?

    public init(
        source: String,
        fileName: String = "<script>",
        defaultTarget: Target? = nil,
        options: Loupe.Options = .default,
        attachmentDirectory: URL? = nil
    ) {
        self.source = source
        self.fileName = fileName
        self.defaultTarget = defaultTarget
        self.options = options
        self.attachmentDirectory = attachmentDirectory
    }
}

/// The one place a script is run on behalf of somebody.
public enum LoupeScript {

    /// Run a script and report what happened.
    ///
    /// Output is always captured into the report and *additionally* echoed to
    /// `echo` when one is given. That split is the whole reason this function
    /// exists rather than each caller driving `ScriptRunner` directly: the CLI
    /// wants prints to appear as they happen, and the MCP tool must not let a
    /// script's `print()` anywhere near standard output, because on a stdio
    /// transport that is the JSON-RPC channel and one stray line ends the
    /// session.
    ///
    /// - Parameter timeout: Give up after this long. A UI flow can wait on a
    ///   screen that never comes, and a caller with no console — an agent — has
    ///   no way to interrupt it.
    ///
    ///   It interrupts a script that is *waiting* — on an element, a sleep, a
    ///   driver — which is every flow that hangs in practice. It cannot
    ///   interrupt a script spinning in a loop that never suspends, because the
    ///   interpreter has no cancellation check of its own; that run continues
    ///   and this call waits for it. Deliberately: returning early would leave
    ///   the run holding its drivers with nobody left to close them.
    public static func run(
        _ request: ScriptRequest,
        timeout: TimeInterval? = nil,
        echo: (@Sendable (String) -> Void)? = nil
    ) async -> ScriptReport {
        let collected = Collector()
        let sink: @Sendable (String) -> Void = { text in
            collected.append(text)
            echo?(text)
        }

        let runner = ScriptRunner(
            options: request.options,
            defaultTarget: request.defaultTarget,
            attachmentDirectory: request.attachmentDirectory)

        let started = Date()
        let (outcome, timedOut) = await withTimeout(timeout) {
            await runner.run(
                source: request.source, fileName: request.fileName,
                output: sink, errorOutput: sink)
        }

        // A script's `print()` can interpolate a password it just typed.
        var report = ScriptReport(
            status: .passed, script: request.fileName,
            duration: outcome?.duration ?? Date().timeIntervalSince(started),
            reason: nil, error: nil,
            issues: (outcome?.issues ?? []).map(Secrets.redact),
            output: Secrets.redact(collected.text),
            attachments: (outcome?.attachments ?? []).map(\.path))

        // A run that ran out of time is exactly the one whose partial findings
        // matter — what already failed, and how far it got — so the report keeps
        // the issues and screenshots the run had produced, and only the verdict
        // is replaced.
        if timedOut {
            report.status = .failed
            report.error = "timed out after \(Self.seconds(timeout)) "
                + "— the script was still running and has been cancelled"
            return report
        }

        switch outcome?.result {
            case .passed, nil:
                report.status = .passed
            case .skipped(let reason):
                report.status = .skipped
                report.reason = reason
            case .failed(let message):
                report.status = .failed
                report.error = Secrets.redact(message)
        }
        return report
    }

    private static func seconds(_ timeout: TimeInterval?) -> String {
        guard let timeout else { return "no time at all" }
        return "\(String(format: "%.0f", timeout))s"
    }

    /// Run `body`, or give up waiting on it.
    ///
    /// Returns whatever the body produced — even when the clock won, because the
    /// group waits for the cancelled run to unwind and the partial result is
    /// worth reporting — plus whether the clock is what ended it.
    private static func withTimeout<T: Sendable>(
        _ timeout: TimeInterval?,
        _ body: @escaping @Sendable () async -> T
    ) async -> (value: T?, timedOut: Bool) {
        // `isFinite` matters as much as `> 0`: an infinite or absurdly large
        // timeout would otherwise overflow the nanosecond conversion below and
        // trap, taking down a long-lived MCP server along with the one call.
        // (A NaN fails `> 0` and lands here too, meaning "no timeout".)
        guard let timeout, timeout > 0, timeout.isFinite else { return (await body(), false) }
        return await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                let nanoseconds = (timeout * 1_000_000_000).rounded()
                try? await Task.sleep(
                    nanoseconds: nanoseconds < Double(UInt64.max)
                        ? UInt64(nanoseconds) : .max)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if let first { return (first, false) }
            // The clock won. Drain the run's own result rather than dropping it:
            // cancellation has already been signalled, and the group will not
            // return until the run has unwound and closed its drivers anyway.
            var recovered: T?
            for await result in group where result != nil { recovered = result }
            return (recovered, true)
        }
    }
}

/// Accumulates a script's output across the concurrent writes the runner makes.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        buffer += text
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
