import Foundation
import LoupeCore

extension SimDriver {
    // MARK: - Apps

    /// Installs (if given a path) and launches an app.
    ///
    /// Environment passthrough: `simctl` forwards every variable in *its own*
    /// environment whose name starts with `SIMCTL_CHILD_` into the launched app,
    /// with the prefix stripped. Loupe inherits the caller's environment, so
    /// exporting `SIMCTL_CHILD_MY_FLAG=1` before running works; `environment:`
    /// below does the same thing per call and adds the prefix for you.
    ///
    /// - Parameters:
    ///   - appOrBundleID: a bundle identifier, or a path to a built `.app`, which is
    ///     installed first and its `CFBundleIdentifier` read from `Info.plist`.
    ///   - arguments: `argv` for the app.
    ///   - environment: variables for the app. Keys are prefixed with
    ///     `SIMCTL_CHILD_` unless they already carry it.
    /// - Returns: a result whose `payload` is the launched process id.
    @discardableResult
    public func launch(
        _ appOrBundleID: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) async throws -> ActionResult {
        let ready = try await ensureReady()
        let device = ready.device

        var bundleID = appOrBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else {
            throw LoupeError.failed("launch needs a bundle identifier or a path to a .app")
        }
        var installedFrom: String?
        if bundleID.hasSuffix(".app") || bundleID.hasSuffix(".app/") {
            let path = try await install(path: bundleID)
            installedFrom = path.path
            bundleID = path.bundleID
        }

        var args = ["launch", "--terminate-running-process", device.udid, bundleID]
        args.append(contentsOf: arguments)

        let childEnvironment = environment.reduce(into: [String: String]()) { result, pair in
            let key = pair.key.hasPrefix("SIMCTL_CHILD_") ? pair.key : "SIMCTL_CHILD_" + pair.key
            result[key] = pair.value
        }
        let output = try await Simctl.check(args, environment: childEnvironment)

        // stdout is exactly `com.example.app: 19493`.
        let pid = output.out.split(separator: ":").last
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { Int($0) }

        // Re-point the bridge at what was just launched. Without this the bridge
        // keeps answering for whichever app it attached to first, so `describe`
        // after `launch` returns a *different app's* tree — successfully, and
        // silently, which is the worst way for this to be wrong.
        Bridge.rememberApp(bundleID, on: device.udid)
        if let bridge = liveBridge.value {
            _ = try? await bridge.attach(bundleID: bundleID, restart: false)
        }

        var message = "launched \(bundleID) on \(device.name)"
        if let installedFrom { message += " (installed from \(installedFrom))" }
        if let pid { message += " — pid \(pid)" }
        return ActionResult(message: message, payload: pid.map(String.init))
    }

    /// Terminates a running app.
    ///
    /// Reports `ok` when the app was not running to begin with: the postcondition
    /// the caller asked for holds. The message says which of the two happened, so
    /// this is disclosure, not a silent no-op.
    @discardableResult
    public func terminate(bundleID: String) async throws -> ActionResult {
        let ready = try await ensureReady()
        let args = ["terminate", ready.device.udid, bundleID]
        let output = try await Simctl.run(args)
        if output.succeeded {
            return ActionResult(message: "terminated \(bundleID)")
        }
        if output.diagnostics.contains("found nothing to terminate") {
            return ActionResult(message: "\(bundleID) was not running — nothing to terminate")
        }
        throw LoupeError.failed(Simctl.failureMessage(args: args, output: output))
    }

    /// Installs a built `.app` bundle onto the device.
    /// - Returns: the standardized path and the bundle identifier read from its `Info.plist`.
    @discardableResult
    public func install(path: String) async throws -> (path: String, bundleID: String) {
        let ready = try await ensureReady()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw LoupeError.targetNotFound("no app bundle at \(url.path)")
        }
        // Read the identifier first: if Info.plist is unreadable the install would
        // succeed and leave the caller with nothing to launch.
        let bundleID = try Simctl.bundleIdentifier(atAppPath: url.path)
        try await Simctl.check(["install", ready.device.udid, url.path])
        return (url.path, bundleID)
    }

    @discardableResult
    public func uninstall(bundleID: String) async throws -> ActionResult {
        let ready = try await ensureReady()
        try await Simctl.check(["uninstall", ready.device.udid, bundleID])
        return ActionResult(message: "uninstalled \(bundleID) from \(ready.device.name)")
    }

    // MARK: - Inventory

    /// Every simulator device on this Mac, booted or not.
    ///
    /// Static because listing devices is how a caller *finds* a locator, before
    /// there is a driver to ask.
    public static func listDevices() async throws -> [SimulatorDevice] {
        try await Simctl.devices()
    }
}
