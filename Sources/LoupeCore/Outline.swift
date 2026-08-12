import Foundation

/// The indented, one-line-per-element form of a tree.
///
/// This used to live in the CLI, which meant the good renderer was reserved for
/// humans at a terminal while every agent got raw JSON of the same tree — about
/// four times the bytes to say the same thing, since JSON spends them on braces,
/// quotes and a repeated key name per field while indentation encodes parenthood
/// for free. Measured on a real window: 21,298 chars of JSON against 5,181 of
/// outline, same nodes, same handles.
///
/// It lives in Core now because both surfaces want it, and because a pure
/// `[UINode] -> String` is the only part of describe that can be tested without
/// a live app on the other end.
public enum Outline {

    /// Render a described tree.
    ///
    /// - Parameters:
    ///   - nodes: Roots, in the order the driver returned them.
    ///   - header: One line of provenance — target, depth, what was collapsed.
    ///     Worth the line: an agent that cannot see how the tree was bounded
    ///     cannot tell "the app has nothing here" from "you did not ask deep
    ///     enough", and those two call for opposite next moves.
    ///   - actions: Include what each element advertises. Off by default: on a
    ///     real window 25 of 41 action-bearing nodes carried the same
    ///     `{ShowDefaultUI,ShowAlternateUI}` pair, which pushed the labels — the
    ///     part a reader is scanning for — off to the right behind noise. It is
    ///     off rather than filtered because any rule for which actions to hide is
    ///     a guess about which affordances an agent will need, made by someone
    ///     who cannot see the app. `--json` always carries all of them.
    public static func render(
        _ nodes: [UINode], header: String? = nil, actions: Bool = false
    ) -> String {
        var lines: [String] = []
        if let header, !header.isEmpty { lines.append(header) }
        for node in nodes { append(node, indent: 0, actions: actions, into: &lines) }
        return lines.joined(separator: "\n")
    }

    /// One element, then whatever it is hiding.
    private static func append(
        _ node: UINode, indent: Int, actions showActions: Bool, into lines: inout [String]
    ) {
        let pad = String(repeating: "  ", count: indent)
        var line = pad + node.role
        if let label = node.label, !label.isEmpty { line += " \"\(label)\"" }
        if let value = node.value, !value.isEmpty, value != node.label { line += " = \(value)" }
        if let identifier = node.identifier, !identifier.isEmpty { line += " #\(identifier)" }
        if !node.enabled { line += " (disabled)" }
        if node.focused { line += " (focused)" }
        if showActions, let actions = actionList(node.actions) { line += " \(actions)" }
        line += "  [\(node.id)]"
        lines.append(line)

        for child in node.children {
            append(child, indent: indent + 1, actions: showActions, into: &lines)
        }

        if let elided = node.elided {
            lines.append(
                String(repeating: "  ", count: indent + 1)
                    + note(for: elided, at: node.id))
        }
    }

    /// What this element advertises, verbatim apart from the `AX` prefix.
    ///
    /// Deliberately not filtered down to the actions that "matter". A control
    /// that offers only `ShowMenu`, or nothing at all, is exactly the case worth
    /// seeing — one real app shipped a button advertising `Press` that did
    /// nothing when pressed, and the list is what said to reach for a real click
    /// instead. Any rule for hiding the boring ones is a guess about which
    /// affordances an agent will need, made by someone who cannot see the app.
    ///
    /// Duplicates are dropped because they are an artifact, not a fact:
    /// `AXUIElementCopyActionNames` returns `Press` twice on some AppKit
    /// controls, and a reader would otherwise take that as meaningful.
    static func actionList(_ actions: [String]) -> String? {
        guard !actions.isEmpty else { return nil }
        var seen = Set<String>()
        let names =
            actions
            .map { $0.hasPrefix("AX") ? String($0.dropFirst(2)) : $0 }
            .filter { seen.insert($0).inserted }
        return "{\(names.joined(separator: ","))}"
    }

    /// The line that stands in for what was not walked.
    ///
    /// Always carries the call that undoes it, because the alternative is an
    /// agent inventing one — and the handle it would have to guess is exactly
    /// the thing it cannot see.
    static func note(for elided: Elision, at handle: String) -> String {
        let count = elided.children
        let noun = count == 1 ? "child" : "children"
        let why =
            switch elided.reason {
                case .depth: "depth cap reached"
                case .budget: "node budget spent"
                case .collapsed: "collapsed"
            }
        return "… \(count) \(noun) not expanded — \(why)  (describe at \(handle))"
    }

    /// A one-line census of a tree, for the header.
    public static func census(_ nodes: [UINode]) -> String {
        let all = nodes.flatMap { $0.flattened() }
        let withheld = all.compactMap(\.elided).reduce(0) { $0 + $1.children }
        var parts = ["\(all.count) node(s) shown"]
        if withheld > 0 { parts.append("\(withheld) not expanded") }
        return parts.joined(separator: ", ")
    }
}
