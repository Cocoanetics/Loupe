import Foundation
import LoupeKit
import SwiftScriptInterpreter

extension XCUIModule {

    func registerElement(into interpreter: Interpreter) {
        registerElementAttributes(into: interpreter)
        registerElementActions(into: interpreter)
        registerElementWaiting(into: interpreter)
        registerAttributeWaiting(into: interpreter)
    }

    // MARK: - Attributes

    private func registerElementAttributes(into interpreter: Interpreter) {

        /// Read one attribute off the resolved node. A missing element is not an
        /// error for attribute reads — XCUI returns empty strings and `false`,
        /// and code leans on that (`if element.label.isEmpty`).
        func attribute(
            _ property: String,
            on receivers: [String] = ["XCUIElement", "XCUIApplication"],
            _ read: @escaping @Sendable (UINode?) -> Value
        ) {
            for receiver in receivers {
                interpreter.bridges["var \(receiver).\(property)"] = .computed { value in
                    let element = try Boxing.element(value, "\(receiver).\(property)")
                    // XCUI attribute reads never raise — `exists` is false and
                    // `label` is empty when there is nothing to read. A driver
                    // that cannot describe (app not running, no window open) must
                    // therefore answer the question, not abort the script: the
                    // standard `if !app.exists { app.launch() }` guard is exactly
                    // the case where describing fails.
                    return read(try? await element.resolveOrNil())
                }
            }
        }

        // Element only: an application's existence is a fact about the process,
        // answered in registerApplicationLifecycle. Registering it here too would
        // silently overwrite that, since attributes register last.
        attribute("exists", on: ["XCUIElement"]) { .bool($0 != nil) }
        attribute("isEnabled") { .bool($0?.enabled ?? false) }
        // XCUI computes hittability from a real hit test. The closest honest
        // stand-in is "has somewhere to be hit".
        attribute("isHittable") { node in
            .bool(!(node?.frame?.isEmpty ?? true) && (node?.enabled ?? false))
        }
        attribute("isSelected") { .bool($0?.focused ?? false) }
        attribute("label") { .string($0?.label ?? "") }
        attribute("identifier") { .string($0?.identifier ?? "") }
        attribute("title") { .string($0?.label ?? "") }
        attribute("value") { Boxing.optionalString($0?.value) }
        attribute("placeholderValue") { _ in Boxing.optionalString(nil) }
        attribute("elementType") { .string($0?.role ?? "any") }
        attribute("frame") { Boxing.rect($0?.frame) }
        attribute("debugDescription", on: ["XCUIElement"]) { node in
            guard let node else { return .string("(no matching element)") }
            return .string(Describe.render([node]))
        }

        // The CGRect-shaped value `frame` hands back.
        for (property, read) in Self.rectAccessors {
            interpreter.bridges["var CGRect.\(property)"] = .computed { value in
                let frame = try Boxing.host(
                    value, as: Frame.self, named: "CGRect", "CGRect.\(property)")
                return .double(read(frame))
            }
        }
    }

    static let rectAccessors: [(String, @Sendable (Frame) -> Double)] = [
        ("minX", { $0.x }), ("minY", { $0.y }),
        ("maxX", { $0.x + $0.width }), ("maxY", { $0.y + $0.height }),
        ("midX", { $0.centerX }), ("midY", { $0.centerY }),
        ("width", { $0.width }), ("height", { $0.height }),
        ("originX", { $0.x }), ("originY", { $0.y })
    ]

    // MARK: - Actions

    private func registerElementActions(into interpreter: Interpreter) {
        registerElementActivation(into: interpreter)
        registerElementTextEntry(into: interpreter)
        registerElementGestures(into: interpreter)
        registerUnavailableGestures(into: interpreter)
    }

    private func registerElementActivation(into interpreter: Interpreter) {
        /// One implementation, several spellings. XCUI splits activation by
        /// platform and forces `#if os(…)` twins; on an accessibility tree there
        /// is one notion of activating a control, so all the spellings land here.
        for spelling in ["tap()", "click()"] {
            interpreter.bridges["func XCUIElement.\(spelling)"] = .method { receiver, _ in
                let element = try Boxing.element(receiver, spelling)
                do {
                    _ = try await element.activate()
                    return .void
                } catch { throw Boxing.runtimeError(error) }
            }
        }

    }

    private func registerElementTextEntry(into interpreter: Interpreter) {
        interpreter.bridges["func XCUIElement.typeText(_:)"] = .method { receiver, args in
            let element = try Boxing.element(receiver, "typeText(_:)")
            let text = try Boxing.string(args.first ?? .void, "typeText(_:)")
            do {
                // `{{PASSWORD}}` resolves from the environment, so a secret is
                // never written into the script and never reaches a transcript.
                _ = try await element.typeText(try EnvironmentInterpolation.expand(text))
                return .void
            } catch { throw Boxing.runtimeError(error) }
        }

        // Not XCUI. There the idiom is select-all-then-type; assigning the value
        // is faster and more reliable through accessibility. macOS refuses it on
        // secure fields, and says so.
        interpreter.bridges["func XCUIElement.setText(_:)"] = .method { receiver, args in
            let element = try Boxing.element(receiver, "setText(_:)")
            let text = try Boxing.string(args.first ?? .void, "setText(_:)")
            do {
                _ = try await element.setText(try EnvironmentInterpolation.expand(text))
                return .void
            } catch { throw Boxing.runtimeError(error) }
        }

    }

    private func registerElementGestures(into interpreter: Interpreter) {
        // Not XCUI, and better than what XCUI offers: ask the app to reveal the
        // element rather than guessing a scroll distance.
        for spelling in ["scrollToVisible()", "reveal()"] {
            interpreter.bridges["func XCUIElement.\(spelling)"] = .method { receiver, _ in
                let element = try Boxing.element(receiver, spelling)
                do {
                    _ = try await element.scrollToVisible()
                    return .void
                } catch { throw Boxing.runtimeError(error) }
            }
        }

        // A real cursor click, for the control AX will not activate. Visible to
        // the user and it needs the window unobscured — hence not the default.
        interpreter.bridges["func XCUIElement.cursorClick()"] = .method { receiver, _ in
            let element = try Boxing.element(receiver, "cursorClick()")
            do {
                _ = try await element.cursorClick()
                return .void
            } catch { throw Boxing.runtimeError(error) }
        }

        // A swipe moves the content the way the finger goes, so swiping up
        // reveals what was below.
        let swipes: [String: (dx: Double, dy: Double)] = [
            "swipeUp": (0, 300), "swipeDown": (0, -300),
            "swipeLeft": (300, 0), "swipeRight": (-300, 0)
        ]
        for (name, delta) in swipes {
            let (dx, dy) = delta
            for labels in ["\(name)()", "\(name)(velocity:)"] {
                interpreter.bridges["func XCUIElement.\(labels)"] = .method { receiver, _ in
                    let element = try Boxing.element(receiver, labels)
                    do {
                        _ = try await element.swipe(dx: dx, dy: dy)
                        return .void
                    } catch { throw Boxing.runtimeError(error) }
                }
            }
        }

        interpreter.bridges["func XCUIElement.screenshot()"] = .method { receiver, _ in
            let element = try Boxing.element(receiver, "screenshot()")
            do {
                return Boxing.value(ScreenshotBox(png: try await element.screenshot()))
            } catch { throw Boxing.runtimeError(error) }
        }

    }

    private func registerUnavailableGestures(into interpreter: Interpreter) {
        // Gestures the accessibility layer cannot express. Failing loudly beats
        // a no-op that leaves the script convinced it opened a context menu.
        let unavailable: [(String, String)] = [
            ("rightClick()", "context menus need a real secondary click, which Loupe cannot synthesize yet"),
            ("doubleTap()", "a double click cannot be expressed as an accessibility action"),
            ("doubleClick()", "a double click cannot be expressed as an accessibility action"),
            ("press(forDuration:)", "a timed press cannot be expressed as an accessibility action"),
            ("press(forDuration:thenDragTo:)", "drag gestures cannot be expressed as accessibility actions"),
            ("twoFingerTap()", "multi-touch gestures require a UI-test runner"),
            ("pinch(withScale:velocity:)", "multi-touch gestures require a UI-test runner"),
            ("rotate(_:withVelocity:)", "multi-touch gestures require a UI-test runner"),
            ("adjust(toNormalizedSliderPosition:)", "slider adjustment is not exposed through accessibility"),
            ("adjust(toPickerWheelValue:)", "picker wheels only exist inside a UI-test runner")
        ]
        for (spelling, reason) in unavailable {
            interpreter.bridges["func XCUIElement.\(spelling)"] = .method { _, _ in
                let name = spelling.prefix(while: { $0 != "(" })
                throw RuntimeError.invalid(
                    "\(name) is not available when running as a script — \(reason)")
            }
        }
    }

    // MARK: - Waiting

    private func registerElementWaiting(into interpreter: Interpreter) {

        interpreter.bridges["func XCUIElement.waitForExistence(timeout:)"] = .method { receiver, args in
            let element = try Boxing.element(receiver, "waitForExistence(timeout:)")
            let timeout = try Boxing.double(args.first ?? .double(5), "waitForExistence(timeout:)")
            do {
                return .bool(try await element.waitForExistence(timeout: timeout))
            } catch { throw Boxing.runtimeError(error) }
        }

        interpreter.bridges["func XCUIElement.waitForNonExistence(timeout:)"] = .method { receiver, args in
            let element = try Boxing.element(receiver, "waitForNonExistence(timeout:)")
            let timeout = try Boxing.double(
                args.first ?? .double(5), "waitForNonExistence(timeout:)")
            do {
                return .bool(try await element.waitForExistence(timeout: timeout, gone: true))
            } catch { throw Boxing.runtimeError(error) }
        }

        // The one addition to the waiting API worth making. Waiting for a
        // dashboard that never arrives burns the whole timeout and then reports
        // nothing useful; racing it against the app's own error label fails in
        // the time the app takes to reject you, and says which error it was.
        for labels in [
            "waitForExistence(timeout:orFailure:)", "waitForExistence(timeout:orFailures:)"
        ] {
            interpreter.bridges["func XCUIElement.\(labels)"] = .method { receiver, args in
                let element = try Boxing.element(receiver, labels)
                let timeout = try Boxing.double(args.first ?? .double(5), labels)
                var failures: [ElementBox] = []
                if args.count > 1 {
                    switch args[1] {
                        case .array(let items):
                            failures = try items.map { try Boxing.element($0, labels) }
                        default:
                            failures = [try Boxing.element(args[1], labels)]
                    }
                }
                do {
                    return .bool(
                        try await element.waitForExistence(timeout: timeout, failures: failures))
                } catch { throw Boxing.runtimeError(error) }
            }
        }

    }

    private func registerAttributeWaiting(into interpreter: Interpreter) {
        // The loop the surveyed tests keep hand-rolling around
        // `RunLoop.current.run(until:)`: wait until a status badge says what it
        // should. `waitForExistence` alone never covered it.
        for labels in ["waitUntil(labelContains:timeout:)", "waitUntil(valueContains:timeout:)"] {
            let attribute = labels.contains("labelContains:") ? "label" : "value"
            interpreter.bridges["func XCUIElement.\(labels)"] = .method { receiver, args in
                let element = try Boxing.element(receiver, labels)
                guard args.count >= 2 else {
                    throw RuntimeError.invalid("\(labels) expects a needle and a timeout")
                }
                let needle = try Boxing.string(args[0], labels)
                let timeout = try Boxing.double(args[1], labels)
                do {
                    return .bool(
                        try await element.waitUntil(
                            attribute: attribute, contains: needle, timeout: timeout))
                } catch { throw Boxing.runtimeError(error) }
            }
        }
    }
}
