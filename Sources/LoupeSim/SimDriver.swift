import CoreGraphics
import Foundation
import LoupeCore

/// Drives an iOS Simulator through public `simctl` only.
///
/// This is the *fast, ad-hoc* way to look at a simulator screen: no test target,
/// no `xcodebuild` cycle, nothing on screen. "Boot it, launch my app, deep-link to
/// the settings screen, show me" is a couple of seconds and three calls, which is
/// what makes a before/after pair around a fix practical.
///
/// It runs headless on purpose — Simulator.app is never opened or required — so a
/// capture never steals focus from the person using the Mac.
///
/// ## What this driver cannot do
///
/// Public `simctl` has no tap, swipe, type, hardware button or accessibility tree.
/// Those need either private CoreSimulator API (what idb and AXe wrap — a
/// dependency Loupe deliberately avoids) or an XCUITest runner bridge, which is a
/// planned future addition to this package. Until then ``describe(_:)`` and the
/// input actions throw ``LoupeError/unsupported(_:)`` with the alternative spelled
/// out, rather than pretending to have done something. A silent no-op that reports
/// success is the single worst failure mode for a verification tool.
///
/// What *is* here: booting, screenshots (with cropping and animation settling),
/// installing and launching apps, deep links, and the determinism knobs — status
/// bar override, appearance, privacy grants — that keep two captures comparable.
///
/// Those live in the `SimDriver+…` files next to this one, which is why the
/// members they share — the resolved-device cache and the screenshot primitives
/// — are module-internal rather than private.
public final class SimDriver: UIDriver {
    /// What the caller asked for: `booted`, a device name like `iPhone 17 Pro`, or
    /// a udid. Resolution happens in ``prepare()``.
    public let deviceLocator: String

    /// Resolved once, then reused. See ``Locked`` for why this is a lock and not
    /// an actor.
    let ready = Locked<Ready?>(nil)

    /// The XCUITest bridge for this device, once started. Held for the driver's
    /// lifetime so a session pays the start-up cost at most once.
    let liveBridge = Locked<Bridge?>(nil)

    /// Everything ``prepare()`` worked out, cached for the driver's lifetime.
    struct Ready: Sendable {
        var device: SimulatorDevice
        var scale: Double
        /// Notes that apply to *every* capture from this driver: "I booted this",
        /// "the scale is a guess", "the clock is live".
        var notes: [String]
    }

    /// Longest we wait for a device to report `Booted` after asking it to boot.
    /// A cold first boot of a new runtime really can take this long.
    private static let bootStateTimeout: Double = 180

    /// Longest we then wait for the framebuffer to answer. `Booted` means
    /// launchd is up, not that there is anything to photograph yet.
    private static let responsiveTimeout: Double = 120

    /// Prefix of the sticky note warning that the status bar is live. Kept as a
    /// constant so ``setStatusBar(time:batteryLevel:wifiBars:cellularBars:)`` can
    /// retract it.
    static let liveStatusBarNote =
        "status bar is not overridden — the clock changes between captures"

    /// - Parameter deviceLocator: `booted` (the first booted simulator), a device
    ///   name (case-insensitive, a booted match wins), or a udid.
    public init(deviceLocator: String = "booted") {
        self.deviceLocator = deviceLocator
    }

    public var targetDescription: String {
        guard let ready = ready.value else { return "sim:\(deviceLocator)" }
        return "sim:\(ready.device.name) (\(ready.device.runtime), \(ready.device.udid))"
    }

    // MARK: - Lifecycle

    /// Resolves the device, boots it if necessary, and works out the backing scale.
    ///
    /// Safe to call repeatedly — the result is cached. ``capture(_:)`` and
    /// ``perform(_:)`` call it themselves, so a caller that goes straight to a
    /// screenshot still gets a booted device.
    public func prepare() async throws {
        _ = try await ensureReady()
    }

    /// Deliberately a no-op: Loupe never shuts a simulator down.
    ///
    /// A booted simulator is shared state. The person at the keyboard may have
    /// Simulator.app pointed at it, another agent may be mid-capture, and rebooting
    /// costs 10–30 seconds of everyone's time. Tearing it down as a side effect of
    /// a read-only verb like `capture` would be indefensible. Booting is explicit
    /// (``prepare()``); shutting down stays the user's call — `xcrun simctl shutdown`.
    public func shutdown() async {}

    @discardableResult
    func ensureReady() async throws -> Ready {
        if let existing = ready.value { return existing }

        var notes: [String] = []
        var device = try await Self.resolveDevice(locator: deviceLocator)

        if !device.isBooted {
            device = try await boot(device, notes: &notes)
        }

        let scale = try await resolveScale(for: device, notes: &notes)

        let statusBarPinned = await hasStatusBarOverride(device)
        if !statusBarPinned {
            notes.append(
                Self.liveStatusBarNote
                    + " — call setStatusBar() before a before/after pair to avoid a false diff")
        }

        let value = Ready(device: device, scale: scale, notes: notes)
        // Last writer wins. Two concurrent ensureReady() calls can only duplicate
        // work (boot is idempotent), never disagree about the answer.
        ready.value = value
        return value
    }

    // MARK: - Device resolution

    /// Turns a locator into a concrete device.
    static func resolveDevice(locator rawLocator: String) async throws -> SimulatorDevice {
        let locator = rawLocator.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = try await Simctl.devices()

        if locator.caseInsensitiveCompare("booted") == .orderedSame {
            let booted = all.filter(\.isBooted)
            guard let first = booted.first else {
                throw LoupeError.targetNotFound(
                    "sim:booted — no simulator is currently booted.\n"
                        + "  Fix: target a device by name instead (e.g. `sim:iPhone 17 Pro`) and Loupe "
                        + "will boot it, or boot one yourself with `xcrun simctl boot \"iPhone 17 Pro\"`.\n"
                        + inventory(all))
            }
            // Refuse to guess. With several devices booted, picking one silently
            // means a flow can run against a different device than the person
            // reading the output believes — and an iPhone and an iPad present
            // the same app very differently, so the result looks like a bug in
            // the app rather than a mistargeted command.
            guard booted.count == 1 else {
                let names = booted.map { "sim:\($0.name)" }.joined(separator: "\n    ")
                throw LoupeError.targetNotFound(
                    "sim:booted is ambiguous — \(booted.count) simulators are booted.\n"
                        + "  Name the one you mean:\n    \(names)")
            }
            return first
        }

        // A udid is an exact match. Compared case-insensitively only because
        // CoreSimulator prints them uppercase and humans paste them lowercased.
        if let byUDID = all.first(where: { $0.udid.caseInsensitiveCompare(locator) == .orderedSame }) {
            return byUDID
        }

        let byName = all.filter { $0.name.caseInsensitiveCompare(locator) == .orderedSame }
        // The same device name exists once per runtime, so prefer the one already
        // running: that is the screen the caller is looking at.
        if let best = byName.first(where: { $0.isBooted })
            ?? byName.first(where: { $0.isAvailable })
            ?? byName.first {
            return best
        }

        throw LoupeError.targetNotFound(
            "sim:\(rawLocator) — no simulator device with that name or udid.\n" + inventory(all))
    }

    /// A short, useful device list to staple onto a "not found" error.
    private static func inventory(_ devices: [SimulatorDevice]) -> String {
        let available = devices.filter(\.isAvailable)
        guard !available.isEmpty else { return "  No available simulator devices." }
        // Booted ones first — that is what a caller most likely meant.
        let ordered = available.filter(\.isBooted) + available.filter { !$0.isBooted }
        let lines = ordered.prefix(12).map { "    \($0.name) — \($0.runtime), \($0.state)" }
        let more = ordered.count > 12 ? "\n    … and \(ordered.count - 12) more" : ""
        return "  Available devices:\n" + lines.joined(separator: "\n") + more
    }

    // MARK: - Booting

    /// Boots a shut-down device and waits until it can actually be photographed.
    private func boot(_ device: SimulatorDevice, notes: inout [String]) async throws
        -> SimulatorDevice {
        guard device.isAvailable else {
            throw LoupeError.failed(
                "\(device.name) (\(device.runtime)) is marked unavailable — its runtime is not "
                    + "installed. Fix: install it from Xcode → Settings → Components.")
        }

        let output = try await Simctl.run(["boot", device.udid], timeout: Self.bootStateTimeout)
        let bootedByUs = output.succeeded
        if !output.succeeded {
            // Boot is idempotent for our purposes: another agent, or Simulator.app,
            // may have won the race between listing the devices and booting one.
            // `Booting` counts too — someone else started it and we can simply wait.
            let underway = output.diagnostics.contains("current state: Booted")
                || output.diagnostics.contains("current state: Booting")
            guard underway else {
                throw LoupeError.failed(Simctl.failureMessage(args: ["boot", device.udid], output: output))
            }
        }

        let booted = try await waitForBootedState(udid: device.udid, name: device.name)
        try await waitUntilResponsive(booted)

        if bootedByUs {
            notes.append("simulator was shut down; Loupe booted \(booted.name) (\(booted.runtime))")
        }
        return booted
    }

    private func waitForBootedState(udid: String, name: String) async throws -> SimulatorDevice {
        let deadline = Date().addingTimeInterval(Self.bootStateTimeout)
        var lastState = "unknown"
        while Date() < deadline {
            if let current = try await Simctl.devices(matching: udid).first(where: { $0.udid == udid }) {
                if current.isBooted { return current }
                lastState = current.state
            } else {
                throw LoupeError.targetNotFound("simulator \(udid) disappeared while booting")
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw LoupeError.timeout(
            "\(name) (\(udid)) did not reach Booted within \(Int(Self.bootStateTimeout))s — "
                + "last state was \(lastState). Fix: `xcrun simctl shutdown \(udid)` and retry, or "
                + "`xcrun simctl erase \(udid)` if it is wedged.")
    }

    /// Waits for the framebuffer, not for launchd.
    ///
    /// `Booted` is reported long before SpringBoard has drawn anything, and a
    /// screenshot taken in that window either fails or returns a black frame. The
    /// screenshot itself is therefore the readiness test — it is the exact
    /// capability the caller is about to use, which beats any proxy signal.
    private func waitUntilResponsive(_ device: SimulatorDevice) async throws {
        let deadline = Date().addingTimeInterval(Self.responsiveTimeout)
        var lastError = "unknown"
        while Date() < deadline {
            do {
                _ = try await rawScreenshot(device)
                return
            } catch {
                lastError = error.localizedDescription
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw LoupeError.timeout(
            "\(device.name) (\(device.udid)) booted but never produced a screenshot within "
                + "\(Int(Self.responsiveTimeout))s. Last error: \(lastError)")
    }

    // MARK: - Scale

    /// Works out how many pixels there are per point on this device's screen.
    ///
    /// Measured, not guessed, whenever possible: the device type's profile bundle
    /// carries `ScreenDimensionsCapability` (`main-screen-width/height/scale`),
    /// which is the same table CoreSimulator itself uses. We cross-check it against
    /// the pixel size of a real screenshot; a mismatch in *both* axes and both
    /// orientations means the profile does not describe what we photographed (a
    /// resizable device, say), so the scale is reported as unverified rather than
    /// silently trusted.
    ///
    /// Only if the profile cannot be read at all do we fall back to the family
    /// convention — 3.0 for iPhone, 2.0 for iPad — and the capture says so in its
    /// notes.
    private func resolveScale(for device: SimulatorDevice, notes: inout [String]) async throws
        -> Double {
        let image = try ImageOps.decode(try await rawScreenshot(device))
        let pixelWidth = image.width
        let pixelHeight = image.height

        let type: SimulatorDeviceType?
        if let identifier = device.deviceTypeIdentifier {
            type = try? await Simctl.deviceType(identifier: identifier)
        } else {
            type = nil
        }

        if let bundlePath = type?.bundlePath,
            let metrics = Simctl.screenMetrics(deviceTypeBundlePath: bundlePath) {
            let matches =
                (metrics.pixelWidth == pixelWidth && metrics.pixelHeight == pixelHeight)
                || (metrics.pixelWidth == pixelHeight && metrics.pixelHeight == pixelWidth)
            if !matches {
                notes.append(
                    "screen is \(pixelWidth)×\(pixelHeight) px but the device profile says "
                        + "\(metrics.pixelWidth)×\(metrics.pixelHeight) px — scale \(metrics.scale) is "
                        + "taken from the profile and may be wrong for this display")
            }
            return metrics.scale
        }

        let assumed = (type?.productFamily ?? "").localizedCaseInsensitiveContains("ipad") ? 2.0 : 3.0
        notes.append(
            "could not read a display profile for \(device.name); assumed scale \(assumed) from the "
                + "device family, so point sizes may be off (pixels are exact: \(pixelWidth)×\(pixelHeight))")
        return assumed
    }
}
