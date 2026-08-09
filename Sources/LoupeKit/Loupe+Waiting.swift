import Foundation
import LoupeCore

// Waiting is the one verb no driver implements. It is nothing but polling
// `describe` until the screen agrees, so a single implementation here serves
// web, mac, simulator and anything added later — and, just as importantly,
// every surface then produces the same wording when a wait fails.
extension Loupe {

    /// Run one action, implementing ``UIAction/waitFor(nodes:failIf:gone:timeout:)``
    /// here rather than in each driver.
    ///
    /// Public because a caller that holds a driver open across many actions — a
    /// live session, a script — must route through here rather than calling
    /// `driver.perform` directly, or every wait throws `.unsupported`.
    @discardableResult
    public static func perform(_ action: UIAction, on driver: any UIDriver) async throws
        -> ActionResult {
        guard case .waitFor(let nodes, let failIf, let gone, let timeout) = action else {
            return try await driver.perform(action)
        }
        return try await waitFor(
            nodes: nodes, failIf: failIf, gone: gone, timeout: timeout, on: driver)
    }

    /// Poll until one of `nodes` is ready (or gone), one of `failIf` shows up, or
    /// the clock runs out.
    private static func waitFor(
        nodes: [String],
        failIf: [String],
        gone: Bool,
        timeout: TimeInterval,
        on driver: any UIDriver
    ) async throws -> ActionResult {
        let deadline = Date().addingTimeInterval(timeout)
        let options = DescribeOptions(maxDepth: 32, interestingOnly: false)
        var seenButDisabled: [String: UINode] = [:]
        var attempts = 0

        while true {
            attempts += 1
            let roots = (try? await driver.describe(options)) ?? []
            let all = roots.flatMap { $0.flattened() }

            // Failures are checked first and win ties: when a screen shows both a
            // stale success marker and a fresh error, the error is the news.
            try failFast(on: failIf, in: all, attempts: attempts)

            let settled = outcome(
                for: nodes, in: all, gone: gone, attempts: attempts,
                seenButDisabled: &seenButDisabled)
            if let settled { return settled }

            if Date() >= deadline { break }
            try await Task.sleep(for: .milliseconds(250))
        }

        throw timedOut(
            nodes: nodes, failIf: failIf, gone: gone, timeout: timeout,
            seenButDisabled: seenButDisabled)
    }

    /// Throw as soon as any of the caller's failure markers is on screen, naming
    /// what it actually said — the label and value are usually the whole story.
    private static func failFast(on failIf: [String], in all: [UINode], attempts: Int) throws {
        for needle in failIf {
            if let hit = match(needle, in: all) {
                let detail = [hit.label, hit.value].compactMap { $0 }.filter { !$0.isEmpty }
                    .joined(separator: " — ")
                throw LoupeError.failed(
                    "'\(needle)' appeared after \(attempts) check(s)"
                        + (detail.isEmpty ? "" : ": \(detail)"))
            }
        }
    }

    /// The result for this poll, or nil to keep waiting. Anything found present
    /// but disabled is remembered in `seenButDisabled` so a timeout can say
    /// "it appeared but never became enabled" rather than "never appeared".
    private static func outcome(
        for nodes: [String],
        in all: [UINode],
        gone: Bool,
        attempts: Int,
        seenButDisabled: inout [String: UINode]
    ) -> ActionResult? {
        for needle in nodes {
            let hit = match(needle, in: all)
            if gone {
                if hit == nil {
                    return ActionResult(
                        message: "'\(needle)' is gone (after \(attempts) check(s))",
                        payload: needle)
                }
            } else if let hit {
                guard hit.enabled else {
                    // Present but disabled is not ready: acting on it would be a
                    // no-op that reports success.
                    seenButDisabled[needle] = hit
                    continue
                }
                return ActionResult(
                    message: "'\(needle)' is ready — \(hit.role)"
                        + (hit.label.map { " \"\($0)\"" } ?? "")
                        + " (after \(attempts) check(s))",
                    payload: needle)
            }
        }
        return nil
    }

    /// A timeout is where a wait either helps or wastes an hour, so each of the
    /// three ways to run out of time gets its own wording.
    private static func timedOut(
        nodes: [String],
        failIf: [String],
        gone: Bool,
        timeout: TimeInterval,
        seenButDisabled: [String: UINode]
    ) -> LoupeError {
        let waited = Int(timeout)
        let expected = nodes.isEmpty ? "(nothing)" : nodes.joined(separator: "' or '")
        if gone {
            return LoupeError.timeout("'\(expected)' was still present after \(waited)s")
        }
        if let stuck = seenButDisabled.first {
            return LoupeError.timeout(
                "'\(stuck.key)' appeared but never became enabled within \(waited)s — it may be "
                    + "waiting on something else, or the wrong element matched")
        }
        return LoupeError.timeout(
            "'\(expected)' never appeared within \(waited)s"
                + (failIf.isEmpty
                    ? ""
                    : ", and none of the expected errors (\(failIf.joined(separator: ", "))) did either")
                + ". Run `loupe describe` to see what is actually on screen")
    }

    /// Same matching rules as ``UIDriver/resolve(_:options:)``, but without the
    /// throw: absence is the normal case while polling.
    private static func match(_ needle: String, in all: [UINode]) -> UINode? {
        if let exact = all.first(where: { $0.id == needle }) { return exact }
        if let byIdentifier = all.first(where: { $0.identifier == needle }) { return byIdentifier }
        if let byLabel = all.first(where: { $0.label == needle }) { return byLabel }
        let fuzzy = all.filter { $0.matches(needle) }
        return fuzzy.first(where: { !$0.actions.isEmpty && $0.enabled }) ?? fuzzy.first
    }
}
