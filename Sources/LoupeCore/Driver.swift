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
        // No exact hit. Report the near misses rather than acting on the best of
        // them: a substring match is a guess, and a guess that presses something
        // is the worst outcome this tool can produce — `press "de"` activating
        // Delete Account reads exactly like success. Naming the candidates costs
        // one round trip and leaves the choice where it belongs.
        let candidates = all.filter { $0.matches(needle) }
        guard candidates.isEmpty else {
            let listed = candidates.prefix(6).map { node -> String in
                let name = node.label ?? node.value ?? node.id
                let identifier = node.identifier.map { " #\($0)" } ?? ""
                return "\(node.role) \"\(name)\"\(identifier) → \(node.id)"
            }
            throw LoupeError.nodeNotFound(
                "\(needle) — nothing matches that exactly. \(candidates.count) element(s) contain "
                    + "it:\n    " + listed.joined(separator: "\n    ")
                    + (candidates.count > 6 ? "\n    …" : "")
                    + "\n  Name one exactly, or use its handle.")
        }
        throw LoupeError.nodeNotFound(needle)
    }
}
