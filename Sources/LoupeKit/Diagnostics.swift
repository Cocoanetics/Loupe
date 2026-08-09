import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import LoupeCore

/// `loupe doctor`.
///
/// Permissions on macOS fail in ways that look like bugs — an empty tree instead
/// of "you lack Accessibility", a black image instead of "you lack Screen
/// Recording". One command that names the missing grant and the exact remedy
/// saves the caller, human or agent, a long detour.
public enum Diagnostics {

    public struct Report: Sendable {
        public var lines: [String]
        public var allGood: Bool
    }

    @MainActor
    public static func run() async -> Report {
        var lines: [String] = []
        var good = true

        func check(
            _ label: String, _ passed: Bool, _ remedy: String? = nil, warnOnly: Bool = false
        ) {
            lines.append("\(passed ? "✓" : "✗") \(label)")
            if !passed {
                if let remedy { lines.append("    → \(remedy)") }
                if !warnOnly { good = false }
            }
        }

        lines.append("Web (offscreen WKWebView)")
        // WebKit ships with the OS and needs no grant at all — the reason the web
        // leg is the cheapest of the three.
        check("WebKit available, no permissions required", true)

        lines.append("")
        lines.append("Mac apps (Accessibility + ScreenCaptureKit)")
        let trusted = AXIsProcessTrusted()
        check(
            "Accessibility (read the element tree, press buttons)", trusted,
            "System Settings → Privacy & Security → Accessibility → add \(executableName()). "
                + "Grants bind to the code signature, so an unsigned binary loses this on every rebuild.")
        let locked =
            ((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Int) == 1
        check(
            "screen is unlocked", !locked,
            "macOS blocks all screen capture while the login window is up. Accessibility keeps "
                + "working, so describe and actions still run — only images are unavailable.",
            warnOnly: true)
        let canCapture = CGPreflightScreenCaptureAccess()
        check(
            "Screen Recording (window screenshots)", canCapture,
            "System Settings → Privacy & Security → Screen & System Audio Recording → add \(executableName()). "
                + "Run `loupe doctor --request` to trigger the system prompt.")

        lines.append("")
        lines.append("iOS Simulator (simctl)")
        let xcrun = FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")
        check("xcrun present", xcrun, "Install Xcode or the Command Line Tools.")
        if xcrun {
            let devices = (try? SimDeviceProbe.count()) ?? -1
            check(
                "simctl responds (\(devices < 0 ? "error" : "\(devices) device(s)"))", devices >= 0,
                "Check `xcode-select -p` points at a full Xcode install.")
            let booted = (try? SimDeviceProbe.bootedCount()) ?? 0
            check(
                "a simulator is booted (\(booted))", booted > 0,
                "Boot one: `xcrun simctl boot \"iPhone 17 Pro\"` — or Loupe will boot it on demand.",
                warnOnly: true)
        }

        return Report(lines: lines, allGood: good)
    }

    /// Ask the system for Screen Recording, which shows the prompt only once per
    /// binary; Accessibility cannot be prompted for programmatically without the
    /// options dictionary, so we use that too.
    @MainActor
    public static func requestPermissions() {
        _ = CGRequestScreenCaptureAccess()
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private static func executableName() -> String {
        (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "loupe"
    }
}

/// Minimal simctl probe used by `doctor`, kept separate from the driver so a
/// broken Xcode install reports cleanly instead of throwing during setup.
enum SimDeviceProbe {
    static func listJSON() throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw LoupeError.failed("simctl list failed") }
        return json
    }

    static func allDevices() throws -> [[String: Any]] {
        guard let devices = try listJSON()["devices"] as? [String: [[String: Any]]] else { return [] }
        return devices.values.flatMap { $0 }
    }

    static func count() throws -> Int { try allDevices().count }

    static func bootedCount() throws -> Int {
        try allDevices().filter { ($0["state"] as? String) == "Booted" }.count
    }
}
