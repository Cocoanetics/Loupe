import Foundation
import LoupeKit

/// A tree fetched once, together with the parent/child structure a staged query
/// needs to walk it.
///
/// Describing returns roots; almost everything here wants a flat list, and the
/// descent between stages wants the subtree of a given node. Fetching once and
/// carrying both keeps a polling loop to one describe per tick.
struct ResolvedTree: Sendable {
    var roots: [UINode]
    var flat: [UINode]

    init(roots: [UINode]) {
        self.roots = roots
        self.flat = roots.flatMap { $0.flattened() }
    }

    /// Empty is not the same as "nothing on screen" — see `waitForExistence`,
    /// where a failed describe must not read as "the element is gone".
    var isEmpty: Bool { flat.isEmpty }
}

extension QueryBox {

    /// XCUI queries see the whole subtree, so describing shallowly would make
    /// `descendants(matching:)` quietly wrong.
    static let describeOptions = DescribeOptions(maxDepth: 32, interestingOnly: false)

    func tree() async throws -> ResolvedTree {
        let driver = try await app.driver()
        return ResolvedTree(roots: try await driver.describe(Self.describeOptions))
    }

    /// Every node the chain matches, in document order.
    func candidates() async throws -> [UINode] {
        try candidates(in: try await tree())
    }

    /// Walk the chain: reach, narrow, optionally pick, then descend.
    func candidates(in tree: ResolvedTree) throws -> [UINode] {
        var current: [UINode] = []
        for (index, stage) in stages.enumerated() {
            switch stage.relation {
                case .wholeTree:
                    current = tree.flat
                case .descendants:
                    current = Self.deduped(current.flatMap { $0.flattened().dropFirst() })
                case .children:
                    current = Self.deduped(current.flatMap(\.children))
            }
            current = try Self.narrow(current, by: stage.filters)
            if let selection = stage.selection {
                // Narrowing to one node before the next stage descends is the
                // whole point of carrying a selection.
                current = Self.pick(selection, from: current).map { [$0] } ?? []
            }
            // Nothing left; later stages cannot reintroduce anything.
            if current.isEmpty && index < stages.count - 1 { return [] }
        }
        return current
    }

    /// Overlapping subtrees would otherwise report the same node twice — a
    /// nested group's descendants are also its parent's.
    private static func deduped(_ nodes: [UINode]) -> [UINode] {
        var seen = Set<String>()
        return nodes.filter { seen.insert($0.id).inserted }
    }

    static func pick(_ selection: Selection, from candidates: [UINode]) -> UINode? {
        switch selection {
            case .first:
                return candidates.first
            case .index(let index):
                return index >= 0 && index < candidates.count ? candidates[index] : nil
        }
    }

    private static func narrow(_ nodes: [UINode], by filters: [QueryFilter]) throws -> [UINode] {
        var current = nodes
        for filter in filters {
            switch filter {
                case .type(let type):
                    if type.isAny { continue }
                    if let unavailable = type.unavailable {
                        throw LoupeError.unsupported(
                            "\(type.query) is not available on this surface — \(unavailable)")
                    }
                    current = current.filter { type.matches($0) }
                case .key(let key):
                    current = ranked(current, key: key)
                case .identifier(let identifier):
                    current = current.filter { $0.identifier == identifier }
                case .predicate(let predicate):
                    current = try current.filter { try predicate.matches($0) }
                case .containing(let predicate):
                    current = try current.filter { node in
                        try node.flattened().dropFirst().contains { try predicate.matches($0) }
                    }
                case .containingType(let type, let identifier):
                    current = current.filter { node in
                        node.flattened().dropFirst().contains {
                            type.matches($0) && $0.identifier == identifier
                        }
                    }
            }
        }
        return current
    }

    /// XCUI's keyed subscript matches identifier *or* label, exactly.
    ///
    /// Exact-only would reject the single most common real-world case: SwiftUI
    /// merges a row's child texts into one accessibility element, so the label of
    /// the row you want is "Build failed 3m ago", not "Build failed". Every
    /// hand-rolled helper in the surveyed test corpus works around that with a
    /// `CONTAINS[c]` predicate.
    ///
    /// So substring matches are accepted, but *ranked last* — an exact
    /// identifier still beats an exact label, and `firstMatch` therefore lands on
    /// the element XCUI would pick whenever XCUI would have found one at all.
    ///
    /// Deliberately never matches `UINode.id`. Those are Loupe's internal
    /// handles (`w0/g2/b5`, `g2n4`), and letting them through means a key like
    /// `"n"` or `"g"` matches an arbitrary element by accident — silently, and
    /// then taps it.
    static func ranked(_ nodes: [UINode], key: String) -> [UINode] {
        func rank(_ node: UINode) -> Int? {
            if node.identifier == key { return 0 }
            if node.label == key { return 1 }
            if node.value == key { return 2 }
            if node.identifier?.caseInsensitiveCompare(key) == .orderedSame { return 3 }
            if node.label?.caseInsensitiveCompare(key) == .orderedSame { return 4 }
            if node.label?.localizedCaseInsensitiveContains(key) == true { return 5 }
            if node.value?.localizedCaseInsensitiveContains(key) == true { return 6 }
            return nil
        }
        /// A node with how well it matched and where it was, so ties can keep
        /// document order — `sorted(by:)` is not a stable sort.
        struct Scored {
            let node: UINode
            let rank: Int
            let offset: Int
        }
        return
            nodes
            .enumerated()
            .compactMap { entry -> Scored? in
                rank(entry.element).map {
                    Scored(node: entry.element, rank: $0, offset: entry.offset)
                }
            }
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .map(\.node)
    }
}

extension ElementBox {

    /// The node this element currently refers to, or nil if nothing matches.
    func resolveOrNil() async throws -> UINode? {
        try resolveOrNil(in: try await query.tree())
    }

    func resolveOrNil(in tree: ResolvedTree) throws -> UINode? {
        QueryBox.pick(selection, from: try query.candidates(in: tree))
    }

    /// The node, or a failure that names the query as the script wrote it.
    func resolve() async throws -> UINode {
        guard let node = try await resolveOrNil() else {
            throw LoupeError.nodeNotFound(
                "no element matches \(description) — run `loupe describe` to see what is on screen")
        }
        return node
    }

    // MARK: - Waiting

    /// XCUI's `waitForExistence(timeout:)`: poll until it shows up, and report
    /// the outcome as a Bool rather than throwing.
    ///
    /// `failures` has no XCUI equivalent and is the one addition worth making.
    /// Waiting for a dashboard that never arrives burns the whole timeout and
    /// then says nothing useful; racing it against the app's own error label
    /// returns in the time the app takes to reject you. That is the difference
    /// between a one-second login check and a twenty-five-second one.
    ///
    /// A tripped failure returns `false` rather than throwing, for two reasons.
    /// It keeps XCUI's contract — `waitForExistence` reports, it does not raise —
    /// and a script could not act on a throw in any case: the interpreter's
    /// `catch` only sees script-level `throw`, so an error raised inside a bridge
    /// is unrecoverable. Returning the verdict leaves the script free to ask
    /// *which* condition tripped by testing `.exists` on the failure.
    func waitForExistence(
        timeout: TimeInterval, gone: Bool = false, failures: [ElementBox] = []
    ) async throws -> Bool {
        let driver = try await app.driver()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            // A describe can fail transiently — a page mid-navigation has no
            // tree. Distinguish that from a successful empty read, because
            // treating a failure as "nothing is there" would make
            // waitForNonExistence pass instantly against an app it cannot even
            // see, which is the opposite of what it was asked.
            let described = try? await driver.describe(QueryBox.describeOptions)
            if let described {
                let tree = ResolvedTree(roots: described)

                // Checked before the expected element, so a screen showing both
                // an error and the thing you wanted reports the failure it is.
                for failure in failures where try failure.resolveOrNil(in: tree) != nil {
                    return false
                }
                let found = try resolveOrNil(in: tree) != nil
                if found != gone { return true }
            }
            if Date() >= deadline { return false }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Wait until an attribute of this element matches — the "wait until the
    /// status badge says Done" loop that the surveyed tests keep re-writing by
    /// hand around `RunLoop.current.run(until:)`.
    func waitUntil(
        attribute: String, contains needle: String, timeout: TimeInterval
    ) async throws -> Bool {
        let driver = try await app.driver()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let described = try? await driver.describe(QueryBox.describeOptions),
                let node = try resolveOrNil(in: ResolvedTree(roots: described)),
                let actual = try Predicate.attribute(attribute, of: node),
                actual.localizedCaseInsensitiveContains(needle) {
                return true
            }
            if Date() >= deadline { return false }
            try await Task.sleep(for: .milliseconds(250))
        }
    }
}
