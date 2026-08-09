import AppKit
import ApplicationServices
import Foundation
import LoupeCore

extension MacDriver {
    // MARK: - Opening URLs

    func navigate(_ string: String) async throws -> ActionResult {
        try ensureResolved()
        guard let application = runningApplication, let bundleURL = application.bundleURL else {
            throw LoupeError.targetNotFound(appLocator)
        }
        guard let url = URL(string: string), url.scheme != nil else {
            throw LoupeError.failed(
                "'\(string)' is not a URL with a scheme — pass something like https://example.com "
                    + "or myapp://path")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false

        let pid: pid_t = try await withCheckedThrowingContinuation { continuation in
            // Completion-handler form on purpose: it lets the pid — a Sendable
            // scalar — cross back instead of a non-Sendable NSRunningApplication.
            NSWorkspace.shared.open(
                [url], withApplicationAt: bundleURL, configuration: configuration
            ) { launched, error in
                if let error {
                    continuation.resume(throwing: LoupeError.failed(
                        "opening \(url.absoluteString) failed: \(error.localizedDescription)"))
                } else if let launched {
                    continuation.resume(returning: launched.processIdentifier)
                } else {
                    continuation.resume(
                        throwing: LoupeError.failed("opening \(url.absoluteString) returned no app"))
                }
            }
        }
        return ActionResult(
            message: "opened \(url.absoluteString) in \(application.localizedName ?? appLocator) "
                + "without activating it",
            payload: "\(pid)")
    }

    // MARK: - Launching and quitting

    func launch(_ locator: String) async throws -> ActionResult {
        let url = try applicationURL(for: locator)
        let configuration = NSWorkspace.OpenConfiguration()
        // The entire promise of this driver in one line: launch it, do not raise
        // it. `NSWorkspace.launchApplication` is not just deprecated, it has no
        // way to express this.
        configuration.activates = false
        configuration.addsToRecentItems = false

        let pid: pid_t = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: url, configuration: configuration
            ) { launched, error in
                if let error {
                    continuation.resume(throwing: LoupeError.failed(
                        "launching \(url.lastPathComponent) failed: \(error.localizedDescription)"))
                } else if let launched {
                    continuation.resume(returning: launched.processIdentifier)
                } else {
                    continuation.resume(
                        throwing: LoupeError.failed("launching \(url.lastPathComponent) returned no app"))
                }
            }
        }

        // An app is not useful the instant it launches: wait for a window to
        // exist before claiming success, or the very next capture would fail.
        var windowCount = 0
        let element = AXUIElementCreateApplication(pid)
        for _ in 0..<40 {
            windowCount = AXAPI.windows(element).count
            if windowCount > 0 { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        // Point the driver at what we just launched when it is what was asked for,
        // clearing the deferred failure from prepare() so the caller can go
        // straight on to describe or capture in the same session.
        if runningApplication == nil || runningApplication?.isTerminated == true {
            try? await reresolve()
        }
        return ActionResult(
            message: "launched \(url.lastPathComponent) as pid \(pid) without activating it; "
                + "\(windowCount) window(s) available",
            payload: "\(pid)")
    }

    func terminate(_ locator: String) async throws -> ActionResult {
        let wanted = locator.isEmpty ? appLocator : locator
        guard let application = findApplication(matching: wanted).first else {
            throw LoupeError.targetNotFound(
                "no running application matches '\(wanted)' — nothing to terminate")
        }
        let name = application.localizedName ?? wanted
        let pid = application.processIdentifier
        // terminate(), never forceTerminate(): a polite quit lets the app save the
        // user's work. Killing an editor to make a test pass is not a trade this
        // tool gets to make.
        guard application.terminate() else {
            throw LoupeError.failed("\(name) refused the quit request")
        }
        for _ in 0..<50 {
            if application.isTerminated { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if application.isTerminated {
            if application.processIdentifier == runningApplication?.processIdentifier {
                await shutdown()
            }
            return ActionResult(message: "\(name) (pid \(pid)) quit", payload: "\(pid)")
        }
        return ActionResult(
            ok: false,
            message: "\(name) (pid \(pid)) was asked to quit but is still running after 5s — it is "
                + "probably showing a save or confirmation dialog. Describe it and press the right "
                + "button; this driver will not force-kill an app that may hold unsaved work.",
            payload: "\(pid)")
    }

    // MARK: - Finding applications

    /// Bundle id, then exact name, then unique case-insensitive partial name —
    /// in that order, so an exact match always beats a fuzzy one.
    func findApplication(matching locator: String) -> [NSRunningApplication] {
        if locator.lowercased().hasPrefix("pid:") {
            let raw = String(locator.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            guard let pid = pid_t(raw), let application = NSRunningApplication(processIdentifier: pid)
            else { return [] }
            return [application]
        }
        let running = NSWorkspace.shared.runningApplications
        let byBundle = running.filter {
            $0.bundleIdentifier?.caseInsensitiveCompare(locator) == .orderedSame
        }
        if !byBundle.isEmpty { return byBundle }
        let byName = running.filter {
            $0.localizedName?.caseInsensitiveCompare(locator) == .orderedSame
        }
        if !byName.isEmpty { return byName }
        return running.filter {
            $0.activationPolicy == .regular
                && (($0.localizedName ?? "").localizedCaseInsensitiveContains(locator)
                    || ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains(locator))
        }
    }

    /// Resolve a launch locator to an app bundle: a path, a bundle id, or a name
    /// looked up in the usual application folders.
    private func applicationURL(for locator: String) throws -> URL {
        if locator.hasSuffix(".app") || locator.hasPrefix("/") {
            let url = URL(fileURLWithPath: (locator as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LoupeError.targetNotFound("no application bundle at \(url.path)")
            }
            return url
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: locator) {
            return url
        }
        if let running = findApplication(matching: locator).first, let url = running.bundleURL {
            return url
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let searched = [
            "/Applications/\(locator).app",
            "/System/Applications/\(locator).app",
            "/System/Applications/Utilities/\(locator).app",
            "/Applications/Utilities/\(locator).app",
            "\(home)/Applications/\(locator).app"
        ]
        for path in searched where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw LoupeError.targetNotFound(
            "cannot find an application for '\(locator)' — pass a bundle id, an absolute .app path, "
                + "or a name present in: \(searched.joined(separator: ", "))")
    }
}
