import AppKit
import ApplicationServices
import Foundation
import LoupeCore
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
                windows: trusted ? windowTitles(pid: app.processIdentifier) : [])
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
