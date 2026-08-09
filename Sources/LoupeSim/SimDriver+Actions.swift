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

            default:
                throw Self.inputUnsupported(action)
        }
    }

    /// Deep links are the only way to steer a running app from out here, so they
    /// get a real implementation while taps and keystrokes get an explanation.
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

    /// Why an input verb cannot be honored here — and, in every case, what to do
    /// instead.
    ///
    /// Public `simctl` synthesizes no touches, keystrokes or hardware buttons.
    /// Reporting success for one of these would be the single worst failure mode
    /// for a verification tool, so each answer names the concrete alternative
    /// (deep links, `SIMCTL_CHILD_*` seeding, an XCUITest runner) rather than
    /// failing blankly.
    private static func inputUnsupported(_ action: UIAction) -> LoupeError {
        switch action {
            case .press:
                return .unsupported(
                    "press on a simulator — public simctl cannot synthesize taps, and Loupe has no "
                        + "element handles here anyway (see describe). Instead: get to the screen with "
                        + ".launch plus .navigate deep links and verify with capture(); real tapping "
                        + "needs an XCUITest runner or private API (idb/AXe).")

            case .setValue:
                return .unsupported(
                    "setValue on a simulator — public simctl cannot address UI elements or set their "
                        + "values. Instead: seed the state before you look at it — launch the app with "
                        + "SIMCTL_CHILD_* environment variables, or use a deep link that carries the "
                        + "value (.navigate), then capture().")

            case .click:
                return .unsupported(
                    "click on a simulator — public simctl cannot synthesize a touch at a coordinate. "
                        + "Instead: reach the state with .navigate deep links or a SIMCTL_CHILD_-seeded "
                        + ".launch, then capture(); coordinate taps need an XCUITest runner or private "
                        + "API (idb/AXe).")

            case .type:
                return .unsupported(
                    "type on a simulator — public simctl cannot deliver keystrokes. Instead: pass the "
                        + "text in a deep link (.navigate) or through SIMCTL_CHILD_* environment "
                        + "variables at .launch, then capture() to check what the app did with it.")

            case .key:
                return .unsupported(
                    "key on a simulator — public simctl cannot press keyboard or hardware buttons "
                        + "(Home, lock, volume). Instead: use .launch to bring an app up and .terminate "
                        + "to send it away, which covers most of what Home is used for; anything else "
                        + "needs an XCUITest runner or private API (idb/AXe).")

            case .scrollTo:
                return .unsupported(
                    "scrollTo on a simulator — reaching a specific element needs an accessibility tree, "
                        + "which public simctl does not expose. Deep-link to the screen instead "
                        + "(.navigate) and capture there.")

            case .scroll:
                return .unsupported(
                    "scroll on a simulator — public simctl cannot synthesize a drag. Instead: deep-link "
                        + "straight to the screen or list position you want (.navigate) and capture() "
                        + "there; scrolling needs an XCUITest runner or private API (idb/AXe).")

            default:
                // Unreachable: ``perform(_:)`` answers every verb it can honor and
                // only forwards the input ones.
                return .unsupported("\(action) is not something a simulator can be asked to do")
        }
    }
}
