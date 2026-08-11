import Foundation
import LoupeCore
import Testing

@testable import LoupeXCUI

@Suite("Reporting one script run to two surfaces")
struct ScriptReportTests {

    private func run(
        _ source: String, timeout: TimeInterval? = nil,
        echo: (@Sendable (String) -> Void)? = nil
    ) async -> ScriptReport {
        await LoupeScript.run(
            ScriptRequest(source: "import XCUIAutomation\n" + source, fileName: "test"),
            timeout: timeout, echo: echo)
    }

    @Test("what the script printed comes back in the report")
    func outputIsCaptured() async {
        let report = await run(#"print("total is 42")"#)
        #expect(report.status == .passed)
        #expect(report.output == "total is 42\n")
    }

    /// The reason this goes through one function instead of each caller driving
    /// the runner: on a stdio transport, standard output is the JSON-RPC
    /// channel, so a script's `print()` must never be allowed near it.
    @Test("output is captured rather than written, unless a caller asks to echo")
    func echoIsOptIn() async {
        let seen = Recorder()
        let report = await run(#"print("live")"#, echo: { seen.append($0) })
        #expect(report.output == "live\n")
        #expect(seen.text == "live\n", "an echoing caller sees it as well, not instead")

        let quiet = await run(#"print("quiet")"#)
        #expect(quiet.output == "quiet\n")
    }

    @Test("a failed expectation is reported rendered, with the line that failed")
    func failuresCarryTheirSource() async {
        let report = await run(
            """
            XCTAssertTrue(false, "no dashboard")
            """)
        #expect(report.status == .failed)
        #expect(report.isSuccess == false)
        #expect(report.issues.count == 1)
        #expect(report.issues.first?.hasPrefix("test:2:1: error: no dashboard") == true)
        // The rendering the CLI prints and a log shows.
        #expect(report.text.contains("✗ test:2:1: error: no dashboard"))
        #expect(report.text.contains("test FAILED"))
    }

    @Test("a comparison names the values, not just their types")
    func comparisonsShowValues() async {
        let report = await run("XCTAssertEqual(2, 7)")
        #expect(report.status == .failed)
        // "Int != Int" is true and useless.
        #expect(report.issues.first?.contains("Int(2) != Int(7)") == true)
    }

    @Test("a skip is reported as a skip, with its reason")
    func skipIsNotFailure() async {
        let report = await run(#"XCTSkip("no credentials")"#)
        #expect(report.status == .skipped)
        #expect(report.reason == "no credentials")
        #expect(report.isSuccess)
        #expect(report.text.contains("skipped"))
    }

    @Test("a clean run says so")
    func passing() async {
        let report = await run("let x = 1")
        #expect(report.status == .passed)
        #expect(report.issues.isEmpty)
        #expect(report.text.contains("passed"))
    }

    @Test("a script that waits forever is given up on")
    func timeoutInterruptsAWaitingScript() async {
        let report = await run("print(\"before\")\nsleep(30)\nprint(\"after\")", timeout: 0.5)
        #expect(report.status == .failed)
        #expect(report.error?.contains("timed out") == true)
        // Whatever it managed to print before being cut off is still reported —
        // that output is often the only clue to where it got stuck.
        #expect(report.output.contains("before"))
        #expect(!report.output.contains("after"))
    }

    /// A timed-out run is the one whose partial findings matter most: what had
    /// already failed, and how far it got.
    @Test("giving up keeps what the run had already found")
    func timeoutKeepsPartialFindings() async {
        let report = await run(
            """
            XCTFail("this failed before the hang")
            sleep(30)
            """, timeout: 0.5)
        #expect(report.status == .failed)
        #expect(report.error?.contains("timed out") == true)
        #expect(report.issues.count == 1, "the recorded failure must survive the timeout")
        #expect(report.issues.first?.contains("this failed before the hang") == true)
    }

    /// An absurd timeout used to trap in the Double→UInt64 conversion, which on
    /// a long-lived MCP server takes the whole session down with the one call.
    @Test(
        "a timeout too large or too strange to convert means no timeout, not a crash",
        arguments: [Double.infinity, .nan, 1e18, -1])
    func nonsenseTimeoutsAreSurvivable(_ timeout: Double) async {
        let report = await run(#"print("fine")"#, timeout: timeout)
        #expect(report.status == .passed)
        #expect(report.output == "fine\n")
    }

    /// The bridge binds to the import, so forgetting it produces a scope error
    /// about a symbol the script obviously used. Accurate; no help at all.
    @Test("forgetting the import is diagnosed as the missing line it is")
    func missingImportIsExplained() async {
        let report = await LoupeScript.run(
            ScriptRequest(source: "let app = XCUIApplication()\n", fileName: "noimport"))
        #expect(report.status == .failed)
        #expect(report.error?.contains("cannot find 'XCUIApplication'") == true)
        #expect(report.error?.contains("missing its first line") == true)
    }

    /// Asserting on the hint sentence, not on "import XCUIAutomation": the
    /// rendered error quotes the script, so the import line appears in the
    /// message of any script that has one.
    @Test("a scope error in a script that did import is left alone")
    func unrelatedScopeErrorsAreNotHijacked() async {
        let report = await run("let x = totallyUndefinedThing()")
        #expect(report.status == .failed)
        #expect(report.error?.contains("missing its first line") == false)
    }

    @Test("the report survives a round trip as JSON, which is what an agent reads")
    func encodesForAgents() async throws {
        let report = await run(#"XCTFail("nope")"#)
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(ScriptReport.self, from: data)
        #expect(decoded.status == .failed)
        #expect(decoded.issues == report.issues)
        #expect(decoded.script == "test")
    }
}

/// Collects echoed output from the runner's concurrent writes.
///
/// Deliberately its own thing rather than the runner's `Collector`, which it
/// otherwise resembles: this stands in for the *caller's* sink — in production
/// the CLI writing to standard output — and sits on the far side of the `echo:`
/// boundary. Sharing one buffer across both sides would leave `echoIsOptIn`
/// unable to tell "captured" from "echoed", which is the one thing it exists to
/// check.
private final class Recorder: @unchecked Sendable {
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
