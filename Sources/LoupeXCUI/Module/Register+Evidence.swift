import Foundation
import LoupeKit
import SwiftScriptInterpreter

extension XCUIModule {

    /// Before/after comparison, from a script.
    ///
    /// This is what the whole tool is for and it was the one thing a script
    /// could not do. An agent that fixes a UI bug can describe the change, but
    /// "trust me, the totals line up now" is not evidence; the two screenshots
    /// and the diff between them are. Driving the app to the right screen and
    /// then capturing that pair is exactly the shape of work a script is for.
    ///
    /// Not XCUI vocabulary, because XCUI has no notion of it — `screenshot()`
    /// there is an attachment, not a comparison.
    func registerEvidence(into interpreter: Interpreter) {
        let store = ComparisonStore()

        // Uses the driver the script already holds open, rather than the
        // one-shot `Loupe.before`, which opens its own — on a web target that
        // means a fresh page load, throwing away the state the script just
        // navigated to.
        interpreter.bridges["func XCUIApplication.captureBefore(named:)"] = .method { receiver, args in
            let app = try Boxing.app(receiver, "captureBefore(named:)")
            let name = try Boxing.string(args.first ?? .void, "captureBefore(named:)")
            do {
                let capture = try await app.driver().capture(.default)
                try store.recordBefore(
                    name: name, capture: capture, target: app.target.description)
                return .string(store.beforeURL(name).path)
            } catch { throw Boxing.runtimeError(error) }
        }

        interpreter.bridges["func XCUIApplication.captureAfter(named:)"] = .method { receiver, args in
            let app = try Boxing.app(receiver, "captureAfter(named:)")
            let name = try Boxing.string(args.first ?? .void, "captureAfter(named:)")
            do {
                let capture = try await app.driver().capture(.default)
                let outcome = try store.recordAfter(name: name, capture: capture)
                return .opaque(typeName: "LoupeComparison", value: ComparisonBox(
                    outcome: outcome, path: store.compareURL(name).path))
            } catch { throw Boxing.runtimeError(error) }
        }

        for (property, read) in Self.comparisonAccessors {
            interpreter.bridges["var LoupeComparison.\(property)"] = .computed { value in
                let box = try Boxing.host(
                    value, as: ComparisonBox.self, named: "LoupeComparison",
                    "LoupeComparison.\(property)")
                return read(box)
            }
        }
    }

    static let comparisonAccessors: [(String, @Sendable (ComparisonBox) -> Value)] = [
        // The sentence a merge request wants: "2.14% of pixels differ, max
        // channel delta 87, 3 region(s)".
        ("summary", { .string($0.outcome.report.summary) }),
        ("isDifferent", { .bool($0.outcome.report.isDifferent) }),
        ("changedPercent", { .double($0.outcome.report.changedPercent) }),
        ("changedRegions", { .int($0.outcome.report.regions.count) }),
        ("sizeChanged", { .bool($0.outcome.report.sizeChanged) }),
        // The side-by-side proof image, ready to attach to an issue.
        ("path", { .string($0.path) })
    ]
}

/// Carries a finished comparison across the bridge.
final class ComparisonBox: @unchecked Sendable {
    let outcome: ComparisonOutcome
    let path: String

    init(outcome: ComparisonOutcome, path: String) {
        self.outcome = outcome
        self.path = path
    }
}
