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
    /// True when the process holds the Accessibility grant; without it window
    /// titles are unavailable and `mac:` targets cannot be driven.
    public var accessibilityTrusted: Bool

    @MainActor
    public static func collect() async throws -> Inventory {
        let trusted = AXIsProcessTrusted()
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil
        }
        let apps: [App] = running.map { app in
            App(
                name: app.localizedName ?? app.bundleIdentifier ?? "?",
                bundleID: app.bundleIdentifier,
                pid: app.processIdentifier,
                active: app.isActive,
                windows: trusted ? windowTitles(pid: app.processIdentifier) : [],
                windowIDs: trusted ? windowIDs(pid: app.processIdentifier) : [])
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let devices = (try? await SimDriver.listDevices()) ?? []
        let simulators =
            devices
            .filter(\.isAvailable)
            .map { Simulator(name: $0.name, udid: $0.udid, state: $0.state, runtime: $0.runtime) }
            // Booted first: that is almost always the one the caller means.
            .sorted {
                ($0.state == "Booted" ? 0 : 1, $0.name) < ($1.state == "Booted" ? 0 : 1, $1.name)
            }
        return Inventory(apps: apps, simulators: simulators, accessibilityTrusted: trusted)
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

    /// Stable window ids, in the same order as ``windowTitles(pid:)``.
    private static func windowIDs(pid: pid_t) -> [Int] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
                == .success,
            let windows = value as? [AXUIElement]
        else { return [] }
        return windows.map { MacDriver.stableWindowID(of: $0) ?? 0 }
    }

    /// Window titles via the accessibility API. Reading is enough — no activation,
    /// no raising, nothing the user would notice.
    private static func windowTitles(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
                == .success,
            let windows = value as? [AXUIElement]
        else { return [] }
        return windows.map { window in
            var title: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                let string = title as? String {
                return string
            }
            return ""
        }
    }
}
