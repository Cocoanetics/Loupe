import Foundation

/// What every surface must be able to do.
///
/// Deliberately five verbs. Element resolution, scroll-into-view loops, retries
/// and before/after bookkeeping all live above this protocol, so a driver only
/// has to answer "what is on screen", "what does it look like" and "do this".
public protocol UIDriver: Sendable {
    /// Human-readable description of what this driver is pointed at.
    var targetDescription: String { get }

    /// Bring the target into existence if needed (boot a simulator, load a URL,
    /// find the window) without disturbing the user's foreground app.
    func prepare() async throws

    func capture(_ options: CaptureOptions) async throws -> Capture

    func describe(_ options: DescribeOptions) async throws -> [UINode]

    func perform(_ action: UIAction) async throws -> ActionResult

    /// Release anything held open (web view, simulator session). Must be safe to
    /// call twice.
    func shutdown() async
}

extension UIDriver {
    public func prepare() async throws {}
    public func shutdown() async {}

    /// Resolve a node handle or a human description ("Save", "#submit") to a
    /// concrete node, re-describing so the handle is fresh.
    public func resolve(_ needle: String, options: DescribeOptions = .init(maxDepth: 32, interestingOnly: false))
        async throws -> UINode {
        let roots = try await describe(options)
        let all = roots.flatMap { $0.flattened() }
        if let exact = all.first(where: { $0.id == needle }) { return exact }
        if let byIdentifier = all.first(where: { $0.identifier == needle }) { return byIdentifier }
        if let byLabel = all.first(where: { $0.label == needle }) { return byLabel }
        let fuzzy = all.filter { $0.matches(needle) }
        // Prefer something actionable and on-screen over a bare static text that
        // happens to contain the same words.
        if let best = fuzzy.first(where: { !$0.actions.isEmpty && $0.enabled })
            ?? fuzzy.first(where: { $0.enabled }) ?? fuzzy.first {
            return best
        }
        throw LoupeError.nodeNotFound(needle)
    }
}
