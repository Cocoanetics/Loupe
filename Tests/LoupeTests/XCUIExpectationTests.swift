import Foundation
import LoupeCore
import Testing

@testable import LoupeXCUI

@Suite("Expectations record and continue")
struct ExpectationTests {

    /// Runs a script with no target, so nothing here needs a driver.
    private func run(_ source: String) async -> ScriptRunner.Outcome {
        await ScriptRunner().run(source: "import XCUIAutomation\n" + source, fileName: "test")
    }

    @Test("a failed expectation does not stop the run")
    func failureContinues() async {
        let outcome = await run(
            """
            XCTAssertTrue(false, "first")
            XCTAssertEqual(1, 2, "second")
            XCTFail("third")
            """)
        #expect(outcome.issues == ["first", "second", "third"])
        guard case .failed = outcome.result else {
            Issue.record("a run that recorded issues must fail")
            return
        }
    }

    @Test("a clean run passes")
    func cleanRunPasses() async {
        let outcome = await run("XCTAssertTrue(true)\nXCTAssertEqual(2, 2)")
        #expect(outcome.issues.isEmpty)
        guard case .passed = outcome.result else {
            Issue.record("expected a pass, got \(outcome.result)")
            return
        }
    }

    @Test("XCTAssertEqual sees through an optional, as every real test writes it")
    func equalityLiftsOptionals() async {
        // element.value is Optional; `XCTAssertEqual(field.value, "admin")` is
        // the idiomatic line and must be able to pass.
        let outcome = await run(
            """
            let optional: String? = "admin"
            XCTAssertEqual(optional, "admin")
            """)
        #expect(outcome.issues.isEmpty)
    }

    @Test("XCTUnwrap records and stops, unlike an expectation")
    func unwrapThrows() async {
        let outcome = await run(
            """
            let missing: String? = nil
            let value = try XCTUnwrap(missing, "needed a value")
            XCTFail("must not be reached: \\(value)")
            """)
        #expect(outcome.issues == ["needed a value"])
    }

    @Test("XCTUnwrap passes the value through when there is one")
    func unwrapSucceeds() async {
        let outcome = await run(
            """
            let present: String? = "ok"
            let value = try XCTUnwrap(present)
            XCTAssertEqual(value, "ok")
            """)
        #expect(outcome.issues.isEmpty)
    }

    @Test("XCTSkip ends the run without failing it")
    func skipIsNotFailure() async {
        let outcome = await run("XCTSkip(\"no credentials\")\nXCTFail(\"unreachable\")")
        guard case .skipped(let reason) = outcome.result else {
            Issue.record("expected a skip, got \(outcome.result)")
            return
        }
        #expect(reason == "no credentials")
        #expect(outcome.issues.isEmpty)
    }

    @Test("exit(1) is a failure, not a pass")
    func exitStatusIsHonoured() async {
        let outcome = await run("print(\"bailing\")\nexit(1)")
        guard case .failed = outcome.result else {
            Issue.record("a non-zero exit must fail the run")
            return
        }
    }
}
