import Foundation
import LoupeKit

/// The slice of `NSPredicate` that UI tests actually use.
///
/// Real `NSPredicate` is a general expression language; UI-test code uses a
/// vanishingly small corner of it. A survey of ~4,500 lines of existing tests
/// turned up exactly eight shapes, all `<key> <operator> <value>` joined by
/// `AND`. Parsing that corner directly — rather than evaluating a real
/// `NSPredicate` against a synthesized object graph — means reaching past it
/// fails loudly instead of silently not matching.
///
/// Everything is parsed from the **format string**, before substitution. Doing
/// it the other way round lets a *value* change the parse: a button labelled
/// "Search AND Replace" splits into two terms, and one labelled "Like" gets torn
/// apart by the `LIKE` operator. Both were real, and both are impossible once
/// structure is decided before the values are known.
struct Predicate: Sendable {

    enum Comparison: Sendable {
        case equal, notEqual, contains, beginsWith, endsWith, matches
    }

    struct Term: Sendable {
        var key: String
        var comparison: Comparison
        var caseInsensitive: Bool
        var value: String
    }

    var terms: [Term]
    /// `AND` between terms. `OR` is accepted too; mixing them is refused, since
    /// precedence without parentheses is a trap worth failing on.
    var requiresAll: Bool
    /// Kept verbatim so error messages can quote what the script asked for.
    var source: String

    // MARK: - Parsing

    static func parse(format: String, arguments: [String]) throws -> Predicate {
        let upper = format.uppercased()
        let hasAnd = upper.contains(" AND ")
        let hasOr = upper.contains(" OR ")
        if hasAnd && hasOr {
            throw LoupeError.unsupported(
                "predicate mixes AND with OR, which needs parentheses to be unambiguous: '\(format)'")
        }
        let pieces = hasOr ? split(format, on: " OR ") : split(format, on: " AND ")

        var cursor = 0
        let terms = try pieces.map {
            try parseTerm($0, arguments: arguments, cursor: &cursor, whole: format)
        }
        guard cursor == arguments.count else {
            throw LoupeError.failed(
                "predicate '\(format)' takes \(cursor) substitution(s) but \(arguments.count) "
                    + "were given")
        }
        // Rebuild what was actually meant, for error messages.
        let rendered = terms.map { "\($0.key) \($0.value)" }.joined(
            separator: hasOr ? " OR " : " AND ")
        return Predicate(terms: terms, requiresAll: !hasOr, source: "\(format) → \(rendered)")
    }

    /// Case-insensitive split that keeps the pieces' original spelling.
    private static func split(_ text: String, on separator: String) -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        while let range = rest.range(of: separator, options: .caseInsensitive) {
            pieces.append(String(rest[rest.startIndex..<range.lowerBound]))
            rest = rest[range.upperBound...]
        }
        pieces.append(String(rest))
        return pieces
    }

    private static func parseTerm(
        _ raw: String, arguments: [String], cursor: inout Int, whole: String
    ) throws -> Term {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard let found = leftmostOperator(in: text) else {
            throw LoupeError.unsupported(
                "cannot parse predicate term '\(text)' in '\(whole)' — expected "
                    + "<key> <==|!=|CONTAINS|BEGINSWITH|ENDSWITH|MATCHES> <value>")
        }
        let keyFormat = String(text[text.startIndex..<found.range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let valueFormat = String(text[found.range.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        guard !keyFormat.isEmpty else {
            throw LoupeError.unsupported(
                "predicate term '\(text)' in '\(whole)' has no key before its operator")
        }
        // Order matters: the key is written first, so it consumes first.
        let key = try fill(keyFormat, arguments: arguments, cursor: &cursor, whole: whole)
        let value = try fill(valueFormat, arguments: arguments, cursor: &cursor, whole: whole)
        return Term(
            key: key,
            comparison: found.op.comparison,
            caseInsensitive: found.op.foldsCase,
            value: unquote(value))
    }

    /// The operator nearest the start of the term, longest token winning a tie.
    ///
    /// Leftmost rather than longest-anywhere: `label == %@` contains the letters
    /// of `LIKE` only once a value has been substituted, and scanning the whole
    /// term for the longest token is how `== Like` came to be parsed as
    /// `label ==` … `LIKE` … `""`, matching every element.
    private static func leftmostOperator(in text: String) -> (op: Operator, range: Range<String.Index>)? {
        var best: (op: Operator, range: Range<String.Index>)?
        for candidate in operators {
            guard let range = text.range(of: candidate.token, options: [.caseInsensitive])
            else { continue }
            guard let current = best else {
                best = (candidate, range)
                continue
            }
            if range.lowerBound < current.range.lowerBound
                || (range.lowerBound == current.range.lowerBound
                    && candidate.token.count > current.op.token.count) {
                best = (candidate, range)
            }
        }
        return best
    }

    /// Substitute the format specifiers in one fragment, consuming arguments in
    /// order.
    private static func fill(
        _ fragment: String, arguments: [String], cursor: inout Int, whole: String
    ) throws -> String {
        var out = ""
        var index = fragment.startIndex
        while index < fragment.endIndex {
            let character = fragment[index]
            index = fragment.index(after: index)
            guard character == "%", index < fragment.endIndex else {
                out.append(character)
                continue
            }
            let specifier = fragment[index]
            index = fragment.index(after: index)
            switch specifier {
                case "@", "d", "i", "K", "f", "u":
                    guard cursor < arguments.count else {
                        throw LoupeError.failed(
                            "predicate '\(whole)' has more format specifiers than arguments")
                    }
                    out += arguments[cursor]
                    cursor += 1
                case "%":
                    out.append("%")
                default:
                    // Unknown specifier: keep it verbatim rather than eating the
                    // character after it.
                    out.append(character)
                    out.append(specifier)
            }
        }
        return out
    }

    /// One spelling of a comparison, and whether it folds case.
    ///
    /// A named type rather than a tuple: the three fields read identically at
    /// the use site otherwise, and getting `foldsCase` and `comparison` the wrong
    /// way round would silently change every match.
    private struct Operator {
        let token: String
        let comparison: Comparison
        let foldsCase: Bool

        init(_ token: String, _ comparison: Comparison, folding foldsCase: Bool = false) {
            self.token = token
            self.comparison = comparison
            self.foldsCase = foldsCase
        }
    }

    private static let operators: [Operator] = [
        Operator("BEGINSWITH[cd]", .beginsWith, folding: true),
        Operator("BEGINSWITH[c]", .beginsWith, folding: true),
        Operator("BEGINSWITH", .beginsWith),
        Operator("ENDSWITH[cd]", .endsWith, folding: true),
        Operator("ENDSWITH[c]", .endsWith, folding: true),
        Operator("ENDSWITH", .endsWith),
        Operator("CONTAINS[cd]", .contains, folding: true),
        Operator("CONTAINS[c]", .contains, folding: true),
        Operator("CONTAINS", .contains),
        Operator("MATCHES[c]", .matches, folding: true), Operator("MATCHES", .matches),
        Operator("LIKE[c]", .matches, folding: true), Operator("LIKE", .matches),
        Operator("!=", .notEqual), Operator("==", .equal), Operator("=", .equal)
    ]

    private static func unquote(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        let first = raw.first
        if (first == "\"" && raw.last == "\"") || (first == "'" && raw.last == "'") {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    // MARK: - Evaluation

    func matches(_ node: UINode) throws -> Bool {
        var outcomes: [Bool] = []
        for term in terms { outcomes.append(try evaluate(term, against: node)) }
        return requiresAll ? !outcomes.contains(false) : outcomes.contains(true)
    }

    private func evaluate(_ term: Term, against node: UINode) throws -> Bool {
        // Boolean attributes compare against a literal rather than a string.
        switch term.key.lowercased() {
            case "isenabled", "enabled":
                return compareBool(node.enabled, term)
            case "isselected", "selected":
                // Loupe does not track selection separately; the closest honest
                // answer is the focused flag.
                return compareBool(node.focused, term)
            case "ishittable", "hittable":
                return compareBool(!(node.frame?.isEmpty ?? true), term)
            case "exists":
                return compareBool(true, term)
            default:
                break
        }
        return compareString(try Predicate.attribute(term.key, of: node) ?? "", term)
    }

    private func compareBool(_ actual: Bool, _ term: Term) -> Bool {
        let wanted = ["true", "yes", "1"].contains(term.value.lowercased())
        return term.comparison == .notEqual ? actual != wanted : actual == wanted
    }

    private func compareString(_ actual: String, _ term: Term) -> Bool {
        let options: String.CompareOptions = term.caseInsensitive ? [.caseInsensitive] : []
        switch term.comparison {
            case .equal:
                return actual.compare(term.value, options: options) == .orderedSame
            case .notEqual:
                return actual.compare(term.value, options: options) != .orderedSame
            case .contains:
                return actual.range(of: term.value, options: options) != nil
            case .beginsWith:
                return actual.range(of: term.value, options: options.union(.anchored)) != nil
            case .endsWith:
                return actual.range(
                    of: term.value, options: options.union([.anchored, .backwards])) != nil
            case .matches:
                return actual.range(
                    of: term.value, options: options.union(.regularExpression)) != nil
        }
    }

    /// The `XCUIElementAttributes` names a predicate may address, mapped onto
    /// what a `UINode` carries.
    ///
    /// An unknown key throws rather than reading as the empty string. Silently
    /// treating `hasKeyboardFocus == true` as `"" == "true"` makes the query
    /// empty, so a wait burns its full timeout and reports "never appeared" for
    /// an element that is on screen — with nothing pointing at the real cause.
    static func attribute(_ key: String, of node: UINode) throws -> String? {
        switch key.lowercased() {
            case "label": return node.label
            case "identifier": return node.identifier
            case "value": return node.value
            // XCUI's `title` is the window/menu title; Loupe folds it into label.
            case "title": return node.label
            case "placeholdervalue": return nil
            case "elementtype": return node.role
            default:
                throw LoupeError.unsupported(
                    "predicate key '\(key)' is not one this surface models — use "
                        + "label, identifier, value, title, elementType, isEnabled, "
                        + "isSelected, isHittable or exists")
        }
    }
}
