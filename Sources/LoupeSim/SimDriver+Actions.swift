import Foundation
import LoupeCore

extension SimDriver {
    // MARK: - Perform

    public func perform(_ action: UIAction) async throws -> ActionResult {
        let device = try await ensureReady().device

        switch action {
            case .launch(let appOrBundleID):
                return try await launch(appOrBundleID)

            case .terminate(let bundleID):
                return try await terminate(bundleID: bundleID)

            case .navigate(let url):
                return try await openURL(url, on: device)

            case .settle(let timeout):
                return try await settle(timeout: timeout, on: device)

            case .waitFor:
                // Handled above the driver, in Loupe.perform(_:on:), because it is just
                // polling `describe` and one implementation serves every surface.
                throw LoupeError.unsupported(
                    "waitFor is handled by LoupeKit, not by a driver directly — call Loupe.act(...)")

            case .press, .setValue, .type, .key, .click, .scroll, .scrollTo:
                // Input goes through the XCUITest bridge, which is the only
                // route that can both see an element and touch it.
                guard let result = try await performViaBridge(action) else {
                    throw Self.inputUnsupported(action)
                }
                return result

            case .evaluate:
                throw LoupeError.unsupported(
                    "evaluate runs JavaScript and only means something on a `web:` target. On a "
                        + "simulator, use .navigate with a deep link to drive the app instead.")
        }
    }

    /// Deep links reach a screen without going through the UI at all, which is
    /// still the fastest way to set up a state worth looking at.
    private func openURL(_ url: String, on device: SimulatorDevice) async throws -> ActionResult {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LoupeError.failed("navigate needs a URL or deep link")
        }
        try await Simctl.check(["openurl", device.udid, trimmed])
        return ActionResult(
            message: "opened \(trimmed) on \(device.name)", payload: trimmed)
    }

    private func settle(timeout: Double, on device: SimulatorDevice) async throws -> ActionResult {
        let result = try await settledScreenshot(device, timeout: timeout)
        return ActionResult(
            ok: result.settled,
            message: result.settled
                ? String(format: "screen settled within %.1fs", timeout)
                : String(
                    format: "screen was still changing after %.1fs — captures may show an "
                        + "in-flight animation", timeout))
    }

    /// Reached only for a verb the bridge has no mapping for; everything a
    /// simulator can actually be asked to do is handled above.
    private static func inputUnsupported(_ action: UIAction) -> LoupeError {
        .unsupported(
            "\(action) is not something a simulator can be asked to do. Input goes through the "
                + "XCUITest bridge, which covers press, setValue, type, key, click, scroll and "
                + "scrollTo; anything outside that has no equivalent on iOS.")
    }
}
