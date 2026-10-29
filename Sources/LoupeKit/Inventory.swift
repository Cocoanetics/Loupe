import AppKit
import ApplicationServices
import Foundation
import LoupeCore
import LoupeMac
import LoupeSim

/// What is available to point Loupe at right now.
///
/// Exists because the hardest part of driving someone else's UI is knowing what
/// to name: agents guess app names wrong constantly, and a listing costs one
/// call instead of three failed attempts.
public struct Inventory: Codable, Sendable {
    public struct App: Codable, Sendable {
        public var name: String
        public var bundleID: String?
        public var pid: Int32
        public var active: Bool
        /// Window titles, index-aligned with the `mac:Name#N` selector.
        public var windows: [String]
        /// Stable window ids (CGWindowID), index-aligned with ``windows``; 0 when unknown.
        public var windowIDs: [Int] = []
        /// The `#N` index of each entry in ``windows`` when a filter removed some;
        /// nil means the position is the index.
        public var windowIndices: [Int]?
        /// Why ``windows`` could not be read — typically the app did not answer
        /// Accessibility in time — so an empty list here means "unknown", not
        /// "no windows". Nil when the windows were read.
        public var windowsError: String?
    }

    public struct Simulator: Codable, Sendable {
        public var name: String
        public var udid: String
        public var state: String
        public var runtime: String
    }

    public var apps: [App]
    public var simulators: [Simulator]
    /// Why ``simulators`` is empty when listing them failed or ran out of time;
    /// nil when it worked. The Mac apps are listed either way.
    public var simulatorsError: String?
    /// True when the process holds the Accessibility grant; without it window
    /// titles are unavailable and `mac:` targets cannot be driven.
    public var accessibilityTrusted: Bool

    /// The longest `simctl` may take to list devices before the inventory goes
    /// out without them. Normally well under a second; `simctl` stalls when
    /// CoreSimulator is busy booting or driving a device for another process.
    public static let simulatorTimeout: Double = 20

    /// The longest one app may take to answer one Accessibility request while
    /// its windows are read, by default. The system's own is several seconds,
    /// which an app that is busy (being driven by another Loupe, say) or hung
    /// spends in full — per app, in a listing of all of them.
    public static let accessibilityTimeout: Float = 1

    /// Everything running and every simulator, read independently and at once:
    /// a stuck `simctl` cannot hold up the Mac apps, nor an unresponsive app the
    /// simulators.
    ///
    /// - Parameter simulators: false to skip `simctl` altogether, for callers
    ///   that only want the Mac apps.
    /// - Parameter accessibilityTimeout: Seconds each app gets per Accessibility
    ///   request; 0 for the system default, for a caller that would rather wait
    ///   on one busy app than report its windows as unknown.
    public static func collect(
        simulators: Bool = true, accessibilityTimeout: Float = accessibilityTimeout
    ) async throws -> Inventory {
        async let listed = simulators ? listSimulators() : ([], nil)
        let trusted = AXIsProcessTrusted()
        let apps = CallTrace.during("listing Mac apps") {
            macApps(trusted: trusted, timeout: accessibilityTimeout)
        }
        let (devices, error) = await listed
        return Inventory(
            apps: apps, simulators: devices, simulatorsError: error, accessibilityTrusted: trusted)
    }

    /// Regular apps, with their windows when Accessibility is granted.
    ///
    /// `runningApplications` is readable from any thread, so this stays off the
    /// main actor: whatever else this process has queued there cannot delay it.
    private static func macApps(trusted: Bool, timeout: Float) -> [App] {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil
        }
        return running.map { app in
            let name = app.localizedName ?? app.bundleIdentifier ?? "?"
            let pid = app.processIdentifier
            var read = WindowRead(windows: [], error: nil)
            if trusted {
                read = CallTrace.during("reading the windows of \(name) (pid \(pid)) over Accessibility") {
                    windowList(pid: pid, timeout: timeout)
                }
            }
            return App(
                name: name,
                bundleID: app.bundleIdentifier,
                pid: pid,
                active: app.isActive,
                windows: read.windows.map(\.title),
                windowIDs: read.windows.map(\.id),
                windowsError: read.error)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The available simulators, or why there are none to show.
    private static func listSimulators() async -> ([Simulator], String?) {
        let devices: [SimulatorDevice]
        do {
            devices = try await CallTrace.bounded(seconds: simulatorTimeout, "listing simulators") {
                try await SimDriver.listDevices()
            }
        } catch {
            return ([], "\(error)")
        }
        let simulators =
            devices
            .filter(\.isAvailable)
            .map { Simulator(name: $0.name, udid: $0.udid, state: $0.state, runtime: $0.runtime) }
            // Booted first: that is almost always the one the caller means.
            .sorted {
                ($0.state == "Booted" ? 0 : 1, $0.name) < ($1.state == "Booted" ? 0 : 1, $1.name)
            }
        return (simulators, nil)
    }

    /// Only the apps whose name or bundle id contains `app`, and — with a title
    /// pattern — only their matching windows, dropping apps left with none.
    ///
    /// Filtering drops entries from ``App/windows``, so a position in the result
    /// is no longer a `#N` selector; ``App/windowIndices`` keeps the original one.
    public func filtered(app: String?, title: TitlePattern?) -> Inventory {
        var out = self
        if let app {
            out.apps = apps.filter {
                $0.name.localizedCaseInsensitiveContains(app)
                    || ($0.bundleID ?? "").localizedCaseInsensitiveContains(app)
            }
        }
        guard let title else { return out }
        out.apps = out.apps.compactMap { app in
            let kept = app.windows.indices.filter { title.matches(app.windows[$0]) }
            guard !kept.isEmpty else { return nil }
            var filtered = app
            filtered.windows = kept.map { app.windows[$0] }
            filtered.windowIDs = kept.map { $0 < app.windowIDs.count ? app.windowIDs[$0] : 0 }
            filtered.windowIndices = kept.map { app.windowIndices?[$0] ?? $0 }
            return filtered
        }
        return out
    }

    /// Window titles and stable ids (CGWindowID, 0 when unknown) via the
    /// accessibility API. Reading is enough — no activation, no raising, nothing
    /// the user would notice — and each request gives up after `timeout` rather
    /// than waiting on an app that does not answer.
    ///
    /// An app that did not answer comes back with an error rather than an empty
    /// list, which would read as "no windows" — an app in the background.
    private static func windowList(pid: pid_t, timeout: Float) -> WindowRead {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        switch status {
            case .success: break
            // Asked and answered: there is nothing to list.
            case .noValue, .attributeUnsupported: return WindowRead(windows: [], error: nil)
            case .cannotComplete:
                let wait = timeout > 0 ? "within \(String(format: "%g", timeout))s" : "in time"
                return WindowRead(
                    windows: [], error: "the app did not answer Accessibility \(wait); its windows are unknown")
            default:
                return WindowRead(
                    windows: [], error: "reading its windows over Accessibility failed (AXError \(status.rawValue))")
        }
        guard let windows = value as? [AXUIElement] else { return WindowRead(windows: [], error: nil) }
        let list = windows.map { window in
            // Per element: the application's timeout does not carry over.
            AXUIElementSetMessagingTimeout(window, timeout)
            var title: CFTypeRef?
            let text =
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success
                ? title as? String ?? "" : ""
            return (text, MacDriver.stableWindowID(of: window) ?? 0)
        }
        return WindowRead(windows: list, error: nil)
    }

    /// One app's windows, or why they could not be read.
    private struct WindowRead {
        var windows: [(title: String, id: Int)]
        var error: String?
    }
}
