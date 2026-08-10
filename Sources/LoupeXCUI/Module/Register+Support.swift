import Foundation
import LoupeKit
import SwiftScriptInterpreter

extension XCUIModule {

    func registerSupport(into interpreter: Interpreter) {
        registerPredicate(into: interpreter)
        registerScreenshot(into: interpreter)
        registerAssertions(into: interpreter)
        registerGlobals(into: interpreter)
    }

    // MARK: - NSPredicate

    private func registerPredicate(into interpreter: Interpreter) {
        // NSPredicate is variadic. The interpreter dispatches on the exact
        // label list, so each arity a test might write needs its own key —
        // otherwise `NSPredicate(format: "%@ AND %@", a, b)` fails with
        // "cannot find 'NSPredicate' in scope", which points nowhere useful.
        var spellings = ["init NSPredicate(format:)"]
        for count in 1...6 {
            spellings.append("init NSPredicate(format:\(String(repeating: "_:", count: count)))")
        }
        for labels in spellings {
            interpreter.bridges[labels] = .`init` { args in
                guard let first = args.first else {
                    throw RuntimeError.invalid("NSPredicate(format:) expects a format string")
                }
                let format = try Boxing.string(first, "NSPredicate(format:)")
                // NSPredicate's variadic arguments arrive either spread across
                // the call or already collected into an array.
                var substitutions: [String] = []
                for argument in args.dropFirst() {
                    if case .array(let items) = argument {
                        substitutions += try items.map { try Boxing.string($0, "NSPredicate") }
                    } else {
                        substitutions.append(try Boxing.string(argument, "NSPredicate"))
                    }
                }
                do {
                    return Boxing.value(
                        try Predicate.parse(format: format, arguments: substitutions))
                } catch { throw Boxing.runtimeError(error) }
            }
        }
        interpreter.bridges["var NSPredicate.predicateFormat"] = .computed { value in
            let predicate = try Boxing.host(
                value, as: Predicate.self, named: "NSPredicate", "predicateFormat")
            return .string(predicate.source)
        }
    }

    // MARK: - Screenshots

    private func registerScreenshot(into interpreter: Interpreter) {
        interpreter.bridges["var XCUIScreenshot.pngRepresentation"] = .computed { value in
            let shot = try Boxing.host(
                value, as: ScreenshotBox.self, named: "XCUIScreenshot", "pngRepresentation")
            return .opaque(typeName: "Data", value: shot.png)
        }

        // In a test the idiom is `XCTAttachment(…)` with `.keepAlways`; a script
        // has no test report to attach to, so the equivalent is naming the shot
        // and letting the runner write them all out together.
        let session = session
        for labels in ["func XCUIScreenshot.attach(named:)", "func XCUIScreenshot.save(named:)"] {
            interpreter.bridges[labels] = .method { receiver, args in
                let shot = try Boxing.host(
                    receiver, as: ScreenshotBox.self, named: "XCUIScreenshot", labels)
                let name = try Boxing.string(args.first ?? .string("screenshot"), labels)
                await session.record(attachment: name, png: shot.png)
                return .void
            }
        }

        interpreter.bridges["func XCUIScreenshot.write(to:)"] = .method { receiver, args in
            let shot = try Boxing.host(
                receiver, as: ScreenshotBox.self, named: "XCUIScreenshot", "write(to:)")
            let path = try Boxing.string(args.first ?? .void, "write(to:)")
            do {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                try shot.png.write(to: url)
                return .string(url.path)
            } catch { throw Boxing.runtimeError(error) }
        }
    }

    // MARK: - Expectations

    /// Assertions, with Swift Testing's failure model.
    ///
    /// The target vocabulary is `#expect` / `#require`. Both are freestanding
    /// macros, and the interpreter cannot evaluate a macro expansion yet
    /// (SwiftScript#14) — the whole reason they *are* macros is that
    /// `#expect(a == b)` reports the expression's source text and the operand
    /// values, which a plain function never sees.
    ///
    /// So the spellings offered here are the XCTest ones, which are real API
    /// that compiles in a test target. What has been taken from Swift Testing is
    /// the part that matters more than the spelling: **an expectation records an
    /// issue and lets the run continue**, and only the unwrapping form throws.
    /// That is XCTest's real behaviour too — `XCTAssertTrue` has never stopped a
    /// test — and it is what lets one script report every problem it found
    /// rather than the first.
    private func registerAssertions(into interpreter: Interpreter) {
        let session = session

        func expectation(_ name: String, expecting expected: Bool) {
            interpreter.registerGlobal(name: name) { args in
                let actual = try Boxing.bool(args.first ?? .void, name)
                guard actual != expected else { return .void }
                let comment = args.count > 1 ? try Boxing.string(args[1], name) : nil
                await session.record(
                    issue: comment ?? "\(name) failed: expected \(expected)",
                    at: interpreter.currentCallOffset)
                return .void
            }
        }
        expectation("XCTAssertTrue", expecting: true)
        expectation("XCTAssert", expecting: true)
        expectation("XCTAssertFalse", expecting: false)

        interpreter.registerGlobal(name: "XCTAssertEqual") { args in
            guard args.count >= 2 else {
                throw RuntimeError.invalid("XCTAssertEqual expects two values")
            }
            // `element.value` is Optional in XCUI too, and every real test writes
            // `XCTAssertEqual(field.value, "admin")` or the `as? String` form.
            // Comparing the boxed values raw makes both always fail.
            guard Boxing.lifted(args[0]) != Boxing.lifted(args[1]) else { return .void }
            let comment = args.count > 2 ? try Boxing.string(args[2], "XCTAssertEqual") : nil
            await session.record(
                issue: comment
                    ?? "XCTAssertEqual failed: \(Boxing.describe(args[0])) "
                        + "!= \(Boxing.describe(args[1]))",
                at: interpreter.currentCallOffset)
            return .void
        }

        interpreter.registerGlobal(name: "XCTAssertNotEqual") { args in
            guard args.count >= 2 else {
                throw RuntimeError.invalid("XCTAssertNotEqual expects two values")
            }
            guard Boxing.lifted(args[0]) == Boxing.lifted(args[1]) else { return .void }
            let comment = args.count > 2 ? try Boxing.string(args[2], "XCTAssertNotEqual") : nil
            await session.record(
                issue: comment ?? "XCTAssertNotEqual failed: both are \(Boxing.describe(args[0]))",
                at: interpreter.currentCallOffset)
            return .void
        }

        registerUnwrapping(into: interpreter)
    }

    /// The nil-shaped expectations, and the two that end the run.
    private func registerUnwrapping(into interpreter: Interpreter) {
        let session = session

        interpreter.registerGlobal(name: "XCTAssertNil") { args in
            if case .optional(let inner) = args.first ?? .void, inner == nil { return .void }
            let comment = args.count > 1 ? try Boxing.string(args[1], "XCTAssertNil") : nil
            await session.record(issue: comment ?? "XCTAssertNil failed", at: interpreter.currentCallOffset)
            return .void
        }

        interpreter.registerGlobal(name: "XCTAssertNotNil") { args in
            if case .optional(let inner) = args.first ?? .void, inner == nil {
                let comment = args.count > 1 ? try Boxing.string(args[1], "XCTAssertNotNil") : nil
                await session.record(
                    issue: comment ?? "XCTAssertNotNil failed", at: interpreter.currentCallOffset)
            }
            return .void
        }

        interpreter.registerGlobal(name: "XCTFail") { args in
            let message = args.isEmpty ? "XCTFail" : try Boxing.string(args[0], "XCTFail")
            await session.record(issue: message, at: interpreter.currentCallOffset)
            return .void
        }

        // The one that throws — XCTest's spelling of Swift Testing's `#require`.
        // Records the issue *and* stops, for the precondition where carrying on
        // would only produce noise.
        interpreter.registerGlobal(name: "XCTUnwrap") { args in
            let value = args.first ?? .void
            if case .optional(let inner) = value {
                guard let inner else {
                    let comment = args.count > 1 ? try Boxing.string(args[1], "XCTUnwrap") : nil
                    let message = comment ?? "XCTUnwrap failed: value was nil"
                    await session.record(issue: message, at: interpreter.currentCallOffset)
                    throw RuntimeError.invalid(message)
                }
                return inner
            }
            if case .void = value {
                let message = "XCTUnwrap failed: value was nil"
                await session.record(issue: message, at: interpreter.currentCallOffset)
                throw RuntimeError.invalid(message)
            }
            return value
        }

        // Ends the run without marking it failed. `throw XCTSkip("…")` and a bare
        // `XCTSkip("…")` behave the same, since the call is evaluated either way.
        interpreter.registerGlobal(name: "XCTSkip") { args in
            let reason = args.isEmpty ? "" : try Boxing.string(args[0], "XCTSkip")
            throw ScriptSkipped(reason: reason)
        }
    }

    // MARK: - Globals

    private func registerGlobals(into interpreter: Interpreter) {
        // The same `{{NAME}}` machinery the CLI uses, so a credential is read
        // from the environment rather than written into the script.
        interpreter.registerGlobal(name: "env") { args in
            let name = try Boxing.string(args.first ?? .void, "env(_:)")
            do {
                return .string(try EnvironmentInterpolation.expand("{{\(name)}}"))
            } catch { throw Boxing.runtimeError(error) }
        }
    }
}

/// Ends the script without marking it failed — the `XCTSkip` of a runner that
/// has no test report to skip within.
///
/// `ScriptUncatchableError` is the interpreter's word for "this is a signal to
/// the host, not a diagnostic for the script": it reaches the runner as itself
/// rather than boxed, and a script cannot `try?` it away. Which is what a skip
/// wants to be — control flow, not a failure.
struct ScriptSkipped: ScriptUncatchableError {
    let reason: String
}
