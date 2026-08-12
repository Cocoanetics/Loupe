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

    /// A grant only the user can give.
    public enum Grant: String, Sendable, Codable, CaseIterable {
        case accessibility
        case screenRecording

        public var settingsURL: String {
            switch self {
                case .accessibility:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                case .screenRecording:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            }
        }

        /// Whether a fresh grant reaches a process that is already running.
        ///
        /// Accessibility is consulted per call, so a grant takes hold at once.
        /// Screen Recording is read when the process starts, so an already
        /// running one keeps failing until it is restarted — which looks exactly
        /// like the grant not working, and costs an afternoon if nobody says so.
        public var appliesToRunningProcess: Bool { self == .accessibility }
    }

    public struct Check: Sendable, Codable {
        public var name: String
        public var ok: Bool
        /// A failure that leaves the surface usable — a locked screen stops
        /// captures while actions keep working.
        public var warningOnly: Bool
        public var remedy: String?
        /// The grant this check needs, when that is what is missing. Here so a
        /// caller can act on it rather than parse the remedy prose.
        public var grant: Grant?

        public init(
            name: String, ok: Bool, warningOnly: Bool = false, remedy: String? = nil,
            grant: Grant? = nil
        ) {
            self.name = name
            self.ok = ok
            self.warningOnly = warningOnly
            self.remedy = remedy
            self.grant = grant
        }
    }

    public struct Surface: Sendable, Codable {
        public var name: String
        public var checks: [Check]
        public var ok: Bool { checks.allSatisfy { $0.ok || $0.warningOnly } }
    }

    /// What `doctor` found, in both shapes it gets asked for.
    ///
    /// `surfaces` is for a caller that has to decide something; `lines` is for
    /// one that has to show a person. Keeping both is the point: prose written
    /// for a terminal tells an agent to go and run terminal commands.
    public struct Report: Sendable, Codable {
        public var surfaces: [Surface]
        public var lines: [String]
        public var allGood: Bool
        /// Present when the caller asked for grants in the same run, so `--json`
        /// emits one object rather than prose followed by JSON.
        public var requested: [AccessResult]?

        public var missingGrants: [Grant] {
            surfaces.flatMap(\.checks).filter { !$0.ok }.compactMap(\.grant)
        }
    }

    /// What asking for a grant achieved.
    ///
    /// There is deliberately no `promptShown`. Neither
    /// `AXIsProcessTrustedWithOptions` nor `CGRequestScreenCaptureAccess`
    /// reports whether a dialog appeared — both return the current authorization
    /// state — so any such field would be inferred, and the obvious inference is
    /// wrong in exactly the case it would exist to catch: a previously denied
    /// client is still untrusted after asking, which reads identically to never
    /// having been asked. Callers get the states that can actually be observed
    /// and a note about the ambiguity, rather than a confident answer nobody can
    /// derive.
    public struct AccessResult: Sendable, Codable {
        public var grant: Grant
        public var grantedBefore: Bool
        public var grantedNow: Bool
        public var settingsURL: String
        public var note: String
    }

    @MainActor
    public static func run() async -> Report {
        let surfaces = [webSurface(), macSurface(), simulatorSurface()]
        return Report(
            surfaces: surfaces, lines: render(surfaces),
            allGood: surfaces.allSatisfy(\.ok), requested: nil)
    }

    /// The prose form, derived from the structure rather than built beside it.
    ///
    /// One source of truth: when the two were assembled in parallel it was
    /// possible for a caller reading JSON and a person reading the terminal to
    /// be told different things.
    private static func render(_ surfaces: [Surface]) -> [String] {
        var lines: [String] = []
        for surface in surfaces {
            if !lines.isEmpty { lines.append("") }
            lines.append(surface.name)
            for check in surface.checks {
                lines.append("\(check.ok ? "✓" : "✗") \(check.name)")
                if !check.ok, let remedy = check.remedy { lines.append("    → \(remedy)") }
            }
        }
        return lines
    }

    private static func webSurface() -> Surface {
        // WebKit ships with the OS and needs no grant at all — the reason the web
        // leg is the cheapest of the three.
        Surface(
            name: "Web (offscreen WKWebView)",
            checks: [Check(name: "WebKit available, no permissions required", ok: true)])
    }

    @MainActor
    private static func macSurface() -> Surface {
        let locked =
            ((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"]
                as? Int) == 1
        return Surface(
            name: "Mac apps (Accessibility + ScreenCaptureKit)",
            checks: [
                Check(
                    name: "Accessibility (read the element tree, press buttons)",
                    ok: isGranted(.accessibility),
                    remedy: "System Settings → Privacy & Security → Accessibility → add "
                        + "\(executableName()). Grants bind to the code signature, so an unsigned "
                        + "binary loses this on every rebuild. `loupe doctor --request` asks the "
                        + "system for it.",
                    grant: .accessibility),
                Check(
                    name: "screen is unlocked", ok: !locked, warningOnly: true,
                    remedy: "macOS blocks all screen capture while the login window is up. "
                        + "Accessibility keeps working, so describe and actions still run — only "
                        + "images are unavailable."),
                Check(
                    name: "Screen Recording (window screenshots)",
                    ok: isGranted(.screenRecording),
                    remedy: "System Settings → Privacy & Security → Screen & System Audio "
                        + "Recording → add \(executableName()). `loupe doctor --request` asks the "
                        + "system for it; the grant only reaches this process once it is restarted.",
                    grant: .screenRecording)
            ])
    }

    private static func simulatorSurface() -> Surface {
        let xcrun = FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun")
        var checks = [
            Check(
                name: "xcrun present", ok: xcrun,
                remedy: "Install Xcode or the Command Line Tools.")
        ]
        guard xcrun else { return Surface(name: "iOS Simulator (simctl)", checks: checks) }

        let devices = (try? SimDeviceProbe.count()) ?? -1
        checks.append(
            Check(
                name: "simctl responds (\(devices < 0 ? "error" : "\(devices) device(s)"))",
                ok: devices >= 0,
                remedy: "Check `xcode-select -p` points at a full Xcode install."))
        let booted = (try? SimDeviceProbe.bootedCount()) ?? 0
        checks.append(
            Check(
                name: "a simulator is booted (\(booted))", ok: booted > 0, warningOnly: true,
                remedy: "Boot one: `xcrun simctl boot \"iPhone 17 Pro\"` — or Loupe will boot it "
                    + "on demand."))
        return Surface(name: "iOS Simulator (simctl)", checks: checks)
    }

    /// Ask macOS for the grants Loupe needs, and report what that achieved.
    ///
    /// Worth being precise about, because every part of this disappoints someone
    /// who expected it to just work:
    ///
    /// - The system shows each prompt **once per client**. A client that was
    ///   denied — or that answered earlier and had the grant invalidated by a
    ///   rebuild — gets no prompt at all, and the only route left is System
    ///   Settings. Nothing here can detect that case: the APIs report trust, not
    ///   whether they put a dialog on screen, so the note says a prompt may not
    ///   have appeared rather than pretending to know.
    /// - Neither call returns the new state. The user has to answer a dialog
    ///   first, so `grantedNow` is read after the ask and will usually still be
    ///   false; it is the state, not the verdict.
    /// - Screen Recording is read once at process start, so even after the user
    ///   agrees, *this* process stays blind until it is restarted.
    @MainActor
    public static func requestAccess(_ grants: [Grant] = Grant.allCases) async -> [AccessResult] {
        var results: [AccessResult] = []
        for grant in grants {
            let before = isGranted(grant)
            if !before {
                // Return values ignored on purpose: both report authorization,
                // and reading them as "a dialog appeared" is wrong precisely
                // when it matters.
                switch grant {
                    case .accessibility:
                        _ = AXIsProcessTrustedWithOptions(
                            ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                    case .screenRecording:
                        _ = CGRequestScreenCaptureAccess()
                }
            }
            let after = isGranted(grant)
            results.append(
                AccessResult(
                    grant: grant, grantedBefore: before, grantedNow: after,
                    settingsURL: grant.settingsURL,
                    note: note(grant: grant, before: before, after: after)))
        }
        return results
    }

    public static func isGranted(_ grant: Grant) -> Bool {
        switch grant {
            case .accessibility: AXIsProcessTrusted()
            case .screenRecording: CGPreflightScreenCaptureAccess()
        }
    }

    private static func note(grant: Grant, before: Bool, after: Bool) -> String {
        if before { return "already granted; nothing to do." }
        if after {
            return grant.appliesToRunningProcess
                ? "granted, and in effect immediately."
                : "granted, but this process reads it only at startup — restart it."
        }
        return "asked, and not granted yet. Either a dialog is waiting to be answered, or macOS "
            + "had already recorded an answer for this binary and did not ask again — nothing "
            + "here can tell those apart. If no dialog appeared, grant it at "
            + "\(grant.settingsURL)"
            + (grant.appliesToRunningProcess ? "." : ", then restart this process.")
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
