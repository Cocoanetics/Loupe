import Foundation
import LoupeCore

// Reading the page: the tree, and the handle bookkeeping that keeps a reference
// to an element honest across a re-render.

extension WebDriver {

    // MARK: - Describe

    public func describe(_ options: DescribeOptions) async throws -> [UINode] {
        try await exclusive { try await self.describeUnlocked(options) }
    }

    /// ``describe(_:)`` without the exclusion gate, so an action that already holds
    /// the gate can resolve a description without deadlocking on itself.
    private func describeUnlocked(_ options: DescribeOptions) async throws -> [UINode] {
        try await ensureReady()
        let envelope = try await runScript(
            WebScripts.describeTree(
                maxDepth: max(options.maxDepth, 1),
                interestingOnly: options.interestingOnly,
                filter: options.filter,
                generation: generation))
        guard let nodes = envelope.nodes else {
            throw LoupeError.failed("describe returned no tree: \(envelope.message ?? "no reason given")")
        }
        return nodes.map(UINode.init(wire:))
    }

    /// Turn whatever the caller passed as a node reference into a live handle.
    ///
    /// A handle from a previous page is named as stale instead of being looked up —
    /// silently pressing whatever now occupies that slot is how automated tests
    /// produce green runs for broken pages.
    func resolveHandle(_ needle: String) async throws -> (handle: String, note: String?) {
        if let parsed = parseHandle(needle) {
            guard parsed.generation == generation else {
                throw LoupeError.nodeNotFound(
                    "handle \(needle) belongs to page generation \(parsed.generation); this page is generation "
                        + "\(generation). Navigation invalidates handles — call describe again.")
            }
            return (needle, nil)
        }
        // Not a handle: treat it as a description and resolve it the way
        // `UIDriver.resolve` would, but without re-entering the exclusion gate.
        let roots = try await describeUnlocked(
            DescribeOptions(maxDepth: 32, interestingOnly: false, filter: nil))
        let all = roots.flatMap { $0.flattened() }
        if let exact = all.first(where: { $0.identifier == needle })
            ?? all.first(where: { $0.label == needle }) {
            return (exact.id, nil)
        }
        // No exact hit: name the near misses rather than pressing the best of
        // them. A substring match is a guess, and a guess that clicks reads
        // exactly like success.
        let candidates = all.filter { $0.matches(needle) }
        guard candidates.isEmpty else {
            let listed = candidates.prefix(6).map { node -> String in
                let name = node.label ?? node.value ?? node.id
                let identifier = node.identifier.map { " #\($0)" } ?? ""
                return "\(node.role) \"\(name)\"\(identifier) → \(node.id)"
            }
            throw LoupeError.nodeNotFound(
                "\(needle) — nothing on \(currentURL) matches that exactly. "
                    + "\(candidates.count) element(s) contain it:\n    "
                    + listed.joined(separator: "\n    ")
                    + (candidates.count > 6 ? "\n    …" : "")
                    + "\n  Name one exactly, or use its handle.")
        }
        throw LoupeError.nodeNotFound(
            "\(needle) — no element on \(currentURL) has that handle, id, label or text")
    }

    private func parseHandle(_ value: String) -> (generation: Int, index: Int)? {
        guard value.hasPrefix("g"), let separator = value.firstIndex(of: "n"),
            separator > value.startIndex
        else {
            return nil
        }
        let generationText = value[value.index(after: value.startIndex)..<separator]
        let indexText = value[value.index(after: separator)...]
        guard let generation = Int(generationText), let index = Int(indexText) else { return nil }
        return (generation, index)
    }

    private func quoted(_ value: String) -> String { "\"\(value)\"" }
}

// MARK: - Wire decoding

extension UINode {
    /// Build a node from what the injected walker reported.
    init(wire: WireNode) {
        self.init(
            id: wire.id,
            role: wire.role,
            rawRole: wire.rawRole,
            label: wire.label,
            value: wire.value,
            identifier: wire.identifier,
            frame: wire.x.map {
                Frame(x: $0, y: wire.y ?? 0, width: wire.width ?? 0, height: wire.height ?? 0)
            },
            enabled: wire.enabled ?? true,
            focused: wire.focused ?? false,
            actions: wire.actions ?? [],
            children: (wire.children ?? []).map(UINode.init(wire:)))
    }
}
