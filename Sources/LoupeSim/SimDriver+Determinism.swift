import Foundation
import LoupeCore

extension SimDriver {
    // MARK: - Determinism knobs

    /// Freezes the status bar so two captures can be compared byte for byte.
    ///
    /// This matters more than it looks. A live clock changes between "before" and
    /// "after", and a changing clock is a guaranteed non-zero diff on every single
    /// comparison — the tool's core output becomes noise. Battery and signal bars
    /// drift for the same reason. The defaults are Apple's own marketing values.
    ///
    /// Pass `nil` for anything you would rather leave alone; at least one value is
    /// required, because that is what simctl demands.
    @discardableResult
    public func setStatusBar(
        time: String? = "9:41",
        batteryLevel: Int? = 100,
        wifiBars: Int? = 3,
        cellularBars: Int? = 4
    ) async throws -> ActionResult {
        let ready = try await ensureReady()

        var args = ["status_bar", ready.device.udid, "override"]
        args += try Self.statusBarArguments(
            time: time, batteryLevel: batteryLevel, wifiBars: wifiBars, cellularBars: cellularBars)
        guard args.count > 3 else {
            throw LoupeError.failed(
                "setStatusBar needs at least one non-nil value (time, batteryLevel, wifiBars or "
                    + "cellularBars)")
        }

        try await Simctl.check(args)
        // The screen is deterministic now, so retract the warning.
        self.ready.withLock { current in
            current?.notes.removeAll { $0.hasPrefix(Self.liveStatusBarNote) }
        }
        return ActionResult(message: "status bar overridden on \(ready.device.name)")
    }

    /// Validates up front rather than letting simctl reject the combination: its
    /// own message names neither the value it disliked nor the range it wanted.
    private static func statusBarArguments(
        time: String?, batteryLevel: Int?, wifiBars: Int?, cellularBars: Int?
    ) throws -> [String] {
        var args: [String] = []
        if let time {
            guard !time.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw LoupeError.failed("status bar time cannot be empty — pass nil to leave it alone")
            }
            args += ["--time", time]
        }
        if let batteryLevel {
            guard (0...100).contains(batteryLevel) else {
                throw LoupeError.failed("batteryLevel must be 0…100, got \(batteryLevel)")
            }
            args += ["--batteryLevel", String(batteryLevel)]
        }
        if let wifiBars {
            guard (0...3).contains(wifiBars) else {
                throw LoupeError.failed("wifiBars must be 0…3, got \(wifiBars)")
            }
            args += ["--wifiBars", String(wifiBars)]
        }
        if let cellularBars {
            guard (0...4).contains(cellularBars) else {
                throw LoupeError.failed("cellularBars must be 0…4, got \(cellularBars)")
            }
            args += ["--cellularBars", String(cellularBars)]
        }
        return args
    }

    /// Removes every status bar override, restoring the live clock.
    @discardableResult
    public func clearStatusBar() async throws -> ActionResult {
        let ready = try await ensureReady()
        try await Simctl.check(["status_bar", ready.device.udid, "clear"])
        self.ready.withLock { current in
            guard var value = current,
                !value.notes.contains(where: { $0.hasPrefix(Self.liveStatusBarNote) })
            else { return }
            value.notes.append(
                Self.liveStatusBarNote
                    + " — call setStatusBar() before a before/after pair to avoid a false diff")
            current = value
        }
        return ActionResult(message: "status bar overrides cleared on \(ready.device.name)")
    }

    /// Whether anything is currently pinned in the status bar.
    ///
    /// Checked once during ``prepare()`` rather than per capture: `status_bar list`
    /// costs ~0.4 s, which is real money inside a settle loop.
    func hasStatusBarOverride(_ device: SimulatorDevice) async -> Bool {
        guard let output = try? await Simctl.run(["status_bar", device.udid, "list"]),
            output.succeeded
        else { return false }
        // simctl always prints a title and a rule of `=`; anything else is an
        // actual override.
        return output.out
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { !$0.isEmpty && !$0.hasPrefix("=") && !$0.hasSuffix(":") }
    }

    /// Switches the system between `light` and `dark`, the cheapest way to get a
    /// two-appearance screenshot set out of one build.
    @discardableResult
    public func setAppearance(_ mode: String) async throws -> ActionResult {
        let normalized = mode.trimmingCharacters(in: .whitespaces).lowercased()
        guard normalized == "light" || normalized == "dark" else {
            throw LoupeError.failed("appearance must be \"light\" or \"dark\", got \"\(mode)\"")
        }
        let ready = try await ensureReady()
        try await Simctl.check(["ui", ready.device.udid, "appearance", normalized])
        return ActionResult(message: "appearance set to \(normalized) on \(ready.device.name)")
    }

    /// Grants a privacy permission up front so a screenshot shows the feature
    /// rather than a system alert sitting on top of it.
    ///
    /// - Parameter service: a simctl privacy service — `photos`, `photos-add`,
    ///   `camera`, `contacts`, `location`, `location-always`, `microphone`,
    ///   `calendar`, `reminders`, `motion`, `media-library`, `siri`, or `all`.
    @discardableResult
    public func grantPrivacy(service: String, bundleID: String) async throws -> ActionResult {
        let ready = try await ensureReady()
        try await Simctl.check(["privacy", ready.device.udid, "grant", service, bundleID])
        return ActionResult(message: "granted \(service) to \(bundleID)")
    }

    /// Resets a privacy permission back to "will prompt".
    /// - Parameter bundleID: `nil` resets the service for every app on the device.
    @discardableResult
    public func resetPrivacy(service: String, bundleID: String? = nil) async throws -> ActionResult {
        let ready = try await ensureReady()
        var args = ["privacy", ready.device.udid, "reset", service]
        if let bundleID { args.append(bundleID) }
        try await Simctl.check(args)
        return ActionResult(
            message: "reset \(service) for \(bundleID ?? "all apps") on \(ready.device.name)")
    }

    /// Adds photos, live photos, videos or contacts to the device's libraries —
    /// the practical way to get a photo picker or contact list to show something
    /// predictable in a screenshot.
    @discardableResult
    public func addMedia(paths: [String]) async throws -> ActionResult {
        guard !paths.isEmpty else { throw LoupeError.failed("addMedia needs at least one file") }
        let ready = try await ensureReady()
        let resolved = try paths.map { path -> String in
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LoupeError.targetNotFound("no such media file: \(url.path)")
            }
            return url.path
        }
        try await Simctl.check(["addmedia", ready.device.udid] + resolved)
        return ActionResult(
            message: "added \(resolved.count) item(s) to \(ready.device.name)")
    }
}
