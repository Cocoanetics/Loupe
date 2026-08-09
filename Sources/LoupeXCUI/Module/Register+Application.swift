import Foundation
import LoupeKit
import SwiftScriptInterpreter

extension XCUIModule {

    func registerApplication(into interpreter: Interpreter) {
        registerApplicationConstruction(into: interpreter)
        registerApplicationLifecycle(into: interpreter)
        registerApplicationLaunchConfiguration(into: interpreter)
        registerApplicationInput(into: interpreter)
        registerApplicationEvidence(into: interpreter)
    }

    // MARK: - Construction

    private func registerApplicationConstruction(into interpreter: Interpreter) {
        let session = session
        let defaultTarget = defaultTarget

        // `XCUIApplication(bundleIdentifier:)` — by far the most common spelling
        // in real tests, and the one that has to mean the same thing everywhere.
        //
        // A bundle id says *which app*, never *where*. So when the runner was
        // pointed at a device (`--target sim:booted`), the app is that bundle id
        // on that device; with no target, it is a Mac app, whose locator happens
        // to accept a bundle id directly.
        interpreter.bridges["init XCUIApplication(bundleIdentifier:)"] = .`init` { args in
            let bundleID = try Boxing.string(
                args.first ?? .void, "XCUIApplication(bundleIdentifier:)")
            if let defaultTarget, defaultTarget.surface == .sim {
                return Boxing.value(
                    AppBox(target: defaultTarget, bundleID: bundleID, session: session))
            }
            return Boxing.value(
                AppBox(target: Target(surface: .mac, locator: bundleID), session: session))
        }

        // Both at once, for a script that should not depend on how the runner
        // was invoked: `XCUIApplication(target: "sim:booted", bundleIdentifier: …)`.
        interpreter.bridges["init XCUIApplication(target:bundleIdentifier:)"] = .`init` { args in
            guard args.count >= 2 else {
                throw RuntimeError.invalid(
                    "XCUIApplication(target:bundleIdentifier:) expects a target and a bundle id")
            }
            let raw = try Boxing.string(args[0], "XCUIApplication(target:)")
            let bundleID = try Boxing.string(args[1], "XCUIApplication(bundleIdentifier:)")
            do {
                return Boxing.value(
                    AppBox(target: try Target.parse(raw), bundleID: bundleID, session: session))
            } catch { throw Boxing.runtimeError(error) }
        }

        // Not XCUI. A script has to be able to say "the web app" or "the
        // session someone already opened", and there is no bundle identifier
        // for either.
        interpreter.bridges["init XCUIApplication(target:)"] = .`init` { args in
            let raw = try Boxing.string(args.first ?? .void, "XCUIApplication(target:)")
            do {
                return Boxing.value(AppBox(target: try Target.parse(raw), session: session))
            } catch {
                throw Boxing.runtimeError(error)
            }
        }

        // `XCUIApplication()` — in a test it means the target app; here it means
        // whatever the runner was pointed at.
        interpreter.bridges["init XCUIApplication()"] = .`init` { _ in
            guard let defaultTarget else {
                throw RuntimeError.invalid(
                    "XCUIApplication() needs a target — pass one to the runner "
                        + "(loupe script --target mac:MyApp …), or write "
                        + "XCUIApplication(bundleIdentifier:) / XCUIApplication(target:)")
            }
            return Boxing.value(AppBox(target: defaultTarget, session: session))
        }

    }

    // MARK: - Lifecycle

    private func registerApplicationLifecycle(into interpreter: Interpreter) {
        interpreter.bridges["func XCUIApplication.launch()"] = .method { receiver, _ in
            let app = try Boxing.app(receiver, "launch()")
            do {
                _ = try await app.launch()
                return .void
            } catch { throw Boxing.runtimeError(error) }
        }

        // XCUI distinguishes launch from activate; against a running app both
        // mean "make sure it is reachable", so they share an implementation.
        interpreter.bridges["func XCUIApplication.activate()"] = .method { receiver, _ in
            let app = try Boxing.app(receiver, "activate()")
            do {
                _ = try await app.launch()
                return .void
            } catch { throw Boxing.runtimeError(error) }
        }

        interpreter.bridges["func XCUIApplication.terminate()"] = .method { receiver, _ in
            let app = try Boxing.app(receiver, "terminate()")
            do {
                _ = try await app.terminate()
                return .void
            } catch { throw Boxing.runtimeError(error) }
        }

        interpreter.bridges["var XCUIApplication.state"] = .computed { receiver in
            let app = try Boxing.app(receiver, "state")
            return .string(try await app.state())
        }

        // Registered here rather than through attribute(), because "does the
        // app exist" is a question about the process, not about the first node
        // that happens to be in its tree.
        interpreter.bridges["var XCUIApplication.exists"] = .computed { receiver in
            let app = try Boxing.app(receiver, "exists")
            return .bool(((try? await app.state()) ?? "notRunning") != "notRunning")
        }

        interpreter.bridges["var XCUIApplication.running"] = .computed { receiver in
            let app = try Boxing.app(receiver, "running")
            return .bool(try await app.state() != "notRunning")
        }

    }

    // MARK: - Launch configuration

    private func registerApplicationLaunchConfiguration(into interpreter: Interpreter) {
        // XCUI mutates these in place (`app.launchEnvironment["K"] = "v"`).
        // The interpreter resolves a subscript write through a simple variable
        // binding, so a write against a property base cannot reach the host
        // object — assignment of the whole dictionary is the spelling that
        // works, and there is an explicit setter for one-at-a-time use.
        interpreter.bridges["var XCUIApplication.launchEnvironment"] = .computed { receiver in
            let app = try Boxing.app(receiver, "launchEnvironment")
            return .dict(
                app.launchEnvironment
                    .sorted { $0.key < $1.key }
                    .map { DictEntry(key: .string($0.key), value: .string($0.value)) })
        }
        interpreter.bridges["set var XCUIApplication.launchEnvironment"] = .setter { receiver, newValue in
            let app = try Boxing.app(receiver, "launchEnvironment")
            guard case .dict(let entries) = newValue else {
                throw RuntimeError.invalid(
                    "launchEnvironment expects a [String: String], got \(Boxing.describe(newValue))")
            }
            var environment: [String: String] = [:]
            for entry in entries {
                environment[try Boxing.string(entry.key, "launchEnvironment key")] =
                    try Boxing.string(entry.value, "launchEnvironment value")
            }
            app.launchEnvironment = environment
        }
        interpreter.bridges["func XCUIApplication.setLaunchEnvironment(_:_:)"] = .method { receiver, args in
            let app = try Boxing.app(receiver, "setLaunchEnvironment")
            guard args.count == 2 else {
                throw RuntimeError.invalid("setLaunchEnvironment(_:_:) expects a key and a value")
            }
            app.launchEnvironment[try Boxing.string(args[0], "setLaunchEnvironment key")] =
                try Boxing.string(args[1], "setLaunchEnvironment value")
            return .void
        }

        interpreter.bridges["var XCUIApplication.launchArguments"] = .computed { receiver in
            let app = try Boxing.app(receiver, "launchArguments")
            return .array(app.launchArguments.map { Value.string($0) })
        }
        interpreter.bridges["set var XCUIApplication.launchArguments"] = .setter { receiver, newValue in
            let app = try Boxing.app(receiver, "launchArguments")
            guard case .array(let items) = newValue else {
                throw RuntimeError.invalid(
                    "launchArguments expects a [String], got \(Boxing.describe(newValue))")
            }
            app.launchArguments = try items.map { try Boxing.string($0, "launchArguments") }
        }

    }

    // MARK: - Input that is not aimed at one element

    private func registerApplicationInput(into interpreter: Interpreter) {
        interpreter.bridges["func XCUIApplication.typeText(_:)"] = .method { receiver, args in
            let app = try Boxing.app(receiver, "typeText")
            let text = try Boxing.string(args.first ?? .void, "typeText(_:)")
            do {
                _ = try await app.typeText(try EnvironmentInterpolation.expand(text))
                return .void
            } catch { throw Boxing.runtimeError(error) }
        }

        // XCUI takes `XCUIKeyboardKey` constants; strings are what a script can
        // actually write, and they are what Loupe's key parser wants anyway.
        for labels in ["typeKey(_:)", "typeKey(_:modifierFlags:)"] {
            interpreter.bridges["func XCUIApplication.\(labels)"] = .method { receiver, args in
                let app = try Boxing.app(receiver, "typeKey")
                var key = try Boxing.string(args.first ?? .void, "typeKey(_:)")
                if args.count > 1, case .string(let modifiers) = args[1], !modifiers.isEmpty {
                    key = "\(modifiers)+\(key)"
                }
                do {
                    _ = try await app.typeKey(key)
                    return .void
                } catch { throw Boxing.runtimeError(error) }
            }
        }

    }

    // MARK: - Evidence

    private func registerApplicationEvidence(into interpreter: Interpreter) {
        interpreter.bridges["func XCUIApplication.screenshot()"] = .method { receiver, _ in
            let app = try Boxing.app(receiver, "screenshot()")
            do {
                return Boxing.value(ScreenshotBox(png: try await app.screenshot()))
            } catch { throw Boxing.runtimeError(error) }
        }

        // Not XCUI: open a URL or deep link in the target.
        interpreter.bridges["func XCUIApplication.open(_:)"] = .method { receiver, args in
            let app = try Boxing.app(receiver, "open")
            let url = try Boxing.string(args.first ?? .void, "open(_:)")
            do {
                _ = try await app.open(try EnvironmentInterpolation.expand(url))
                return .void
            } catch { throw Boxing.runtimeError(error) }
        }

        // Not XCUI: the tree, for a script that wants to look before it leaps —
        // and for an agent that needs to report what it saw.
        interpreter.bridges["func XCUIApplication.debugDescription()"] = .method { receiver, _ in
            let app = try Boxing.app(receiver, "debugDescription")
            do {
                let roots = try await app.driver().describe(QueryBox.describeOptions)
                return .string(Describe.render(roots))
            } catch { throw Boxing.runtimeError(error) }
        }
        interpreter.bridges["var XCUIApplication.debugDescription"] = .computed { receiver in
            let app = try Boxing.app(receiver, "debugDescription")
            do {
                let roots = try await app.driver().describe(QueryBox.describeOptions)
                return .string(Describe.render(roots))
            } catch { throw Boxing.runtimeError(error) }
        }
    }
}

/// Renders a tree the way `loupe describe` does, so the two agree.
enum Describe {
    static func render(_ roots: [UINode]) -> String {
        var lines: [String] = []
        for root in roots { render(root, depth: 0, into: &lines) }
        return lines.joined(separator: "\n")
    }

    private static func render(_ node: UINode, depth: Int, into lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        var text = "\(indent)\(node.role)"
        if let identifier = node.identifier, !identifier.isEmpty { text += " #\(identifier)" }
        if let label = node.label, !label.isEmpty { text += " \"\(label)\"" }
        if let value = node.value, !value.isEmpty { text += " = \"\(value)\"" }
        if !node.enabled { text += " (disabled)" }
        lines.append(text)
        for child in node.children { render(child, depth: depth + 1, into: &lines) }
    }
}
