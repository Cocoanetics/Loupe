import Foundation

/// What a walk chose not to expand, and why.
///
/// Loupe would rather spend a line than hand back a smaller tree than exists.
/// Before this type, an unnamed container sitting on the depth frontier was
/// spliced away along with everything beneath it — so `describe --depth 3` on a
/// settings window reported nine elements and gave no hint that the entire
/// sidebar had been withheld. An agent reads that as "this app has no
/// accessibility" and goes looking for a bug that is not there.
///
/// Every count here is counted, never estimated, and every elision carries the
/// call that undoes it.
public struct Elision: Codable, Hashable, Sendable {
    public enum Reason: String, Codable, Hashable, Sendable {
        /// The depth cap stopped the walk here.
        case depth
        /// The node budget ran out — the walk was wider than it was allowed to be.
        case budget
        /// Deliberately not expanded: the macOS menu bar under ``DescribeOptions/Scope/primary``.
        case collapsed
    }

    /// Direct children that were not walked.
    public var children: Int
    public var reason: Reason

    public init(children: Int, reason: Reason) {
        self.children = children
        self.reason = reason
    }
}

extension UINode {
    /// Cut this tree back to `maxDepth` levels below its own root, saying what
    /// that hid.
    ///
    /// For surfaces that cannot start a walk partway down. Without it, drilling
    /// into a branch that sat on the depth frontier spent the whole budget
    /// getting *to* the branch and returned the same elided node again — the
    /// disclosure loop never advanced, so an agent following the printed
    /// `describe at …` would repeat it forever.
    public func limited(toDepth maxDepth: Int) -> UINode {
        var copy = self
        guard maxDepth > 0 else {
            if !children.isEmpty {
                copy.children = []
                copy.elided = Elision(children: children.count, reason: .depth)
            }
            return copy
        }
        copy.children = children.map { $0.limited(toDepth: maxDepth - 1) }
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, rawRole, label, value, identifier, frame
        case enabled, focused, actions, children, elided
    }

    /// Hand-written so the wire form carries only what a node actually says.
    ///
    /// The synthesized version emitted every key on every node, and on a real
    /// tree 88% of nodes are leaves — so `"children":[]` alone cost 1,750 chars
    /// of a 33,222-char payload, and `"enabled":true,"focused":false` another
    /// 3,800. Nothing is lost by leaving them out: absent children means leaf,
    /// absent `enabled` means enabled, absent `actions` means none advertised.
    /// ``init(from:)`` restores each default, so this stays a round trip.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encodeIfPresent(rawRole, forKey: .rawRole)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(identifier, forKey: .identifier)
        try container.encodeIfPresent(frame, forKey: .frame)
        if !enabled { try container.encode(false, forKey: .enabled) }
        if focused { try container.encode(true, forKey: .focused) }
        if !actions.isEmpty { try container.encode(actions, forKey: .actions) }
        if !children.isEmpty { try container.encode(children, forKey: .children) }
        try container.encodeIfPresent(elided, forKey: .elided)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(String.self, forKey: .role)
        rawRole = try container.decodeIfPresent(String.self, forKey: .rawRole)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        frame = try container.decodeIfPresent(Frame.self, forKey: .frame)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        focused = try container.decodeIfPresent(Bool.self, forKey: .focused) ?? false
        actions = try container.decodeIfPresent([String].self, forKey: .actions) ?? []
        children = try container.decodeIfPresent([UINode].self, forKey: .children) ?? []
        elided = try container.decodeIfPresent(Elision.self, forKey: .elided)
    }
}
