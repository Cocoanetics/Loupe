import Foundation
import LoupeKit
import SwiftScriptInterpreter

/// How a script ended.
///
/// Skipped is its own outcome rather than a flavour of passed, because a run
/// that never reached its assertions is not evidence that they hold.
public enum ScriptResult: Sendable {
    case passed
    case skipped(reason: String)
    case failed(message: String)
}

/// Runs a UI-test-shaped script against live targets.
///
/// SwiftScript has no dynamic module loading — no `dlopen`, no plugin protocol —
/// so a host that wants to add bridges builds its own binary around the
/// interpreter. That is this: an `Interpreter` with the XCUI surface wired to
/// `import XCUIAutomation`, a session that keeps drivers alive for the whole
/// script, and a tidy-up that runs whether the script passed or threw.
public struct ScriptRunner: Sendable {

    public struct Outcome: Sendable {
        public var result: ScriptResult
        /// Screenshots the script asked to keep, already written to disk.
        public var attachments: [URL]
        /// Every expectation that failed, in the order they were recorded.
        ///
        /// Separate from `result` because a run can finish normally and still
        /// have failed: an expectation records and continues, so the verdict is
        /// only known once the script is done.
        public var issues: [String]
        public var duration: TimeInterval

        public var isSuccess: Bool {
            if case .failed = result { return false }
            return true
        }
    }

    public var options: Loupe.Options
    /// What a bare `XCUIApplication()` resolves to.
    public var defaultTarget: Target?
    /// Where `screenshot().attach(named:)` images are written.
    public var attachmentDirectory: URL?

    public init(
        options: Loupe.Options = .default,
        defaultTarget: Target? = nil,
        attachmentDirectory: URL? = nil
    ) {
        self.options = options
        self.defaultTarget = defaultTarget
        self.attachmentDirectory = attachmentDirectory
    }

    public func run(
        source: String,
        fileName: String = "<script>",
        output: @escaping @Sendable (String) -> Void = { FileHandle.standardOutput.write(Data($0.utf8)) },
        errorOutput: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) async -> Outcome {
        let started = Date()
        let session = XCUISession(options: options)
        let interpreter = Interpreter(output: output, error: errorOutput)
        let module = XCUIModule(session: session, defaultTarget: defaultTarget)

        // The whole point: the import name is matched as a plain string, so a
        // file that says `import XCUIAutomation` gets Apple's framework when it
        // is compiled and this when it is interpreted.
        interpreter.registerOnImport("XCUIAutomation", module: module)
        // A UI test written for a test target imports XCTest, and half the
        // corpus imports Testing instead. Both bring the same surface here.
        interpreter.registerOnImport("XCTest", module: module)
        interpreter.registerOnImport("Testing", module: module)

        var result: ScriptResult
        do {
            // evalScript swallows ScriptExit and reports it here; ignoring the
            // status is how `exit(1)` came to be reported as a pass.
            let status = try await interpreter.evalScript(source, fileName: fileName)
            result = status.isSuccess
                ? .passed
                : .failed(message: "script exited with status \(status.code)")
        } catch let skip as ScriptSkipped {
            result = .skipped(reason: skip.reason)
        } catch {
            result = .failed(message: Secrets.redact(describe(error, using: interpreter)))
        }

        // An expectation that failed does not stop the run, so a script can end
        // normally and still have failed. The verdict is only complete here.
        // Rendered here rather than where they were recorded: only the
        // interpreter can turn an offset into a source listing, and it is the
        // same renderer that reports a thrown error, so a failed expectation and
        // a failed tap read alike.
        let recorded = await session.issues
        let issues = recorded.map { issue -> String in
            guard let offset = issue.offset else { return issue.message }
            return interpreter.renderSourceContext(at: offset, message: issue.message)
        }
        if case .passed = result, !issues.isEmpty {
            result = .failed(
                message: issues.count == 1
                    ? issues[0]
                    : "\(issues.count) expectations failed")
        }

        // Drivers must come down even when the script threw, or a WebKit host
        // outlives the process that owns it.
        var attachments: [URL] = []
        if let attachmentDirectory {
            do {
                attachments = try await session.writeAttachments(to: attachmentDirectory)
            } catch {
                errorOutput("could not write screenshots: \(error.localizedDescription)\n")
            }
        }
        await session.shutdown()

        return Outcome(
            result: result, attachments: attachments, issues: issues,
            duration: Date().timeIntervalSince(started))
    }

    public func run(
        fileURL: URL,
        output: @escaping @Sendable (String) -> Void = { FileHandle.standardOutput.write(Data($0.utf8)) },
        errorOutput: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) }
    ) async throws -> Outcome {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        return await run(
            source: source, fileName: fileURL.lastPathComponent,
            output: output, errorOutput: errorOutput)
    }

    /// Interpreter errors carry the line number; Loupe's carry the remedy.
    /// Both matter, and `localizedDescription` on the raw error loses one or
    /// the other depending on which it is.
    ///
    /// The interpreter already renders `swiftc`-style source context with a
    /// caret, so anything it raises is handed back to it to describe rather than
    /// re-formatted here — that is how a script failure names the line it failed
    /// on instead of only what went wrong.
    private func describe(_ error: any Error, using interpreter: Interpreter) -> String {
        if let loupe = error as? LoupeError { return loupe.errorDescription ?? "\(loupe)" }
        return interpreter.renderRuntimeError(error)
    }
}
