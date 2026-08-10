import Foundation
import LoupeKit

/// Keeps drivers alive for the length of a script.
///
/// The CLI's unit of work is one command, so it opens a driver, acts, and tears
/// it down. A script's unit of work is the whole flow, and paying that cost per
/// statement would be ruinous — for `web:` it means a fresh page load before
/// every single `tap()`, which would also throw away the login you just did.
///
/// So the pool opens one driver per target on first use and holds it until the
/// script ends. `@session` targets are the exception in the other direction:
/// their `shutdown()` is deliberately a no-op, so a script can attach to a
/// session someone else opened and leave it running afterwards.
public actor XCUISession {

    private var drivers: [String: any UIDriver] = [:]
    private let options: Loupe.Options
    /// Screenshots the script asked to keep, in order taken.
    private(set) var attachments: [(name: String, png: Data)] = []
    /// A failure and where in the script it was recorded.
    struct Issue: Sendable {
        var message: String
        /// Source offset of the call that recorded it, when the interpreter
        /// could supply one.
        var offset: Int?
    }

    /// Failures recorded so far. See ``record(issue:at:)``.
    private(set) var issues: [Issue] = []

    public init(options: Loupe.Options = .default) {
        self.options = options
    }

    /// Note a failure without stopping the run.
    ///
    /// Swift Testing's model, and XCTest's actual one: an expectation that fails
    /// records an issue and execution *continues*; only `require` (and
    /// `XCTUnwrap`) throw. For UI automation that is the better half of the
    /// bargain by some distance — one run surfaces every problem, each with the
    /// screenshot that was on screen when it happened, instead of dying on the
    /// first and telling you nothing about the rest.
    ///
    /// A run that completes having recorded issues is still a failed run.
    func record(issue: String, at offset: Int? = nil) {
        issues.append(Issue(message: issue, offset: offset))
    }

    /// The driver for a target, opened on first use.
    func driver(for target: Target) async throws -> any UIDriver {
        let key = target.description
        if let existing = drivers[key] { return existing }
        let driver = try await MainActor.run {
            try Loupe.driver(for: target, options: options)
        }
        try await driver.prepare()
        drivers[key] = driver
        return driver
    }

    func record(attachment name: String, png: Data) {
        attachments.append((name: name, png: png))
    }

    /// Close every driver the script opened.
    public func shutdown() async {
        for driver in drivers.values {
            await driver.shutdown()
        }
        drivers.removeAll()
    }

    /// Write every recorded screenshot into a directory, numbered in the order
    /// they were taken. Returns the files written.
    @discardableResult
    public func writeAttachments(to directory: URL) throws -> [URL] {
        guard !attachments.isEmpty else { return [] }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for (index, attachment) in attachments.enumerated() {
            let safe = attachment.name.replacingOccurrences(of: "/", with: "-")
            let url = directory.appendingPathComponent(
                String(format: "%02d-%@.png", index + 1, safe))
            try attachment.png.write(to: url)
            written.append(url)
        }
        return written
    }
}
