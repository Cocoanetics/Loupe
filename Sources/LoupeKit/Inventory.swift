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
    /// its windows are read. The system default is several seconds, which an app
    /// that is busy (being driven by another Loupe, say) or hung spends in full.
    static let accessibilityTimeout: Float = 1

    /// Everything running and every simulator, read independently and at once:
    /// a stuck `simctl` cannot hold up the Mac apps, nor an unresponsive app the
    /// simulators.
    ///
    /// - Parameter simulators: false to skip `simctl` altogether, for callers
    ///   that only want the Mac apps.
    public static func collect(simulators: Bool = true) async throws -> Inventory {
        async let listed = simulators ? listSimulators() : ([], nil)
        let trusted = AXIsProcessTrusted()
        let apps = CallTrace.during("listing Mac apps") { macApps(trusted: trusted) }
        let (devices, error) = await listed
        return Inventory(
            apps: apps, simulators: devices, simulatorsError: error, accessibilityTrusted: trusted)
    }

    /// Regular apps, with their windows when Accessibility is granted.
    ///
    /// `runningApplications` is readable from any thread, so this stays off the
    /// main actor: whatever else this process has queued there cannot delay it.
    private static func macApps(trusted: Bool) -> [App] {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil
        }
        return running.map { app in
            let name = app.localizedName ?? app.bundleIdentifier ?? "?"
            let pid = app.processIdentifier
            let windows = trusted
                ? CallTrace.during("reading the windows of \(name) (pid \(pid)) over Accessibility") {
                    windowList(pid: pid)
                }
                : []
            return App(
                name: name,
                bundleID: app.bundleIdentifier,
                pid: pid,
                active: app.isActive,
                windows: windows.map(\.title),
                windowIDs: windows.map(\.id))
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
    /// the user would notice — and each request gives up after
    /// ``accessibilityTimeout`` rather than waiting on an app that does not answer.
    private static func windowList(pid: pid_t) -> [(title: String, id: Int)] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, accessibilityTimeout)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
                == .success,
            let windows = value as? [AXUIElement]
        else { return [] }
        return windows.map { window in
            // Per element: the application's timeout does not carry over.
            AXUIElementSetMessagingTimeout(window, accessibilityTimeout)
            var title: CFTypeRef?
            let text =
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success
                ? title as? String ?? "" : ""
            return (text, MacDriver.stableWindowID(of: window) ?? 0)
        }
    }
}
