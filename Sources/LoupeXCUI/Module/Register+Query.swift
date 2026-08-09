import Foundation
import LoupeKit
import SwiftScriptInterpreter

extension XCUIModule {

    func registerQuery(into interpreter: Interpreter) {
        registerQuerySelection(into: interpreter)
        registerQueryMatching(into: interpreter)
        registerQueryTerminals(into: interpreter)
        registerQueryDescendants(into: interpreter)
        registerElementTypeConstants(into: interpreter)
    }

    // MARK: - Picking one element out of a query

    private func registerQuerySelection(into interpreter: Interpreter) {
        // `app.buttons["Sign In"]` — the single most-used idiom in the surveyed
        // corpus after waiting, and the one thing that could not be expressed at
        // all until bridged subscripts landed.
        interpreter.bridges["subscript XCUIElementQuery.get"] = .subscriptGet { receiver, args in
            let query = try Boxing.query(receiver, "subscript")
            guard args.count == 1 else {
                throw RuntimeError.invalid(
                    "an element query takes one subscript argument, got \(args.count)")
            }
            switch args[0] {
                case .string(let key):
                    return Boxing.value(ElementBox(query: query.adding(.key(key))))
                case .int(let index):
                    // Not XCUI — its subscript is keyed only — but `q[0]` is the
                    // obvious thing to try and silently failing would be worse.
                    return Boxing.value(ElementBox(query: query, selection: .index(index)))
                default:
                    throw RuntimeError.invalid(
                        "cannot look an element up by \(Boxing.describe(args[0])) — "
                            + "use a String identifier or label")
            }
        }

        interpreter.bridges["func XCUIElementQuery.element(boundBy:)"] = .method { receiver, args in
            let query = try Boxing.query(receiver, "element(boundBy:)")
            let index = try Boxing.int(args.first ?? .void, "element(boundBy:)")
            return Boxing.value(ElementBox(query: query, selection: .index(index)))
        }

    }

    // MARK: - Narrowing a query

    private func registerQueryMatching(into interpreter: Interpreter) {
        interpreter.bridges["func XCUIElementQuery.matching(identifier:)"] = .method { receiver, args in
            let query = try Boxing.query(receiver, "matching(identifier:)")
            let identifier = try Boxing.string(args.first ?? .void, "matching(identifier:)")
            return Boxing.value(query.adding(.identifier(identifier)))
        }

        interpreter.bridges["func XCUIElementQuery.matching(_:)"] = .method { receiver, args in
            let query = try Boxing.query(receiver, "matching(_:)")
            let predicate = try Boxing.host(
                args.first ?? .void, as: Predicate.self, named: "NSPredicate", "matching(_:)")
            return Boxing.value(query.adding(.predicate(predicate)))
        }

        interpreter.bridges["func XCUIElementQuery.matching(_:identifier:)"] = .method { receiver, args in
            var query = try Boxing.query(receiver, "matching(_:identifier:)")
            if let type = Self.elementType(from: args.first ?? .void) {
                query = query.adding(.type(type))
            }
            if args.count > 1, case .optional(let inner) = args[1], inner == nil {
                return Boxing.value(query)
            }
            if args.count > 1 {
                query = query.adding(
                    .identifier(try Boxing.string(args[1], "matching(_:identifier:)")))
            }
            return Boxing.value(query)
        }

        interpreter.bridges["func XCUIElementQuery.containing(_:)"] = .method { receiver, args in
            let query = try Boxing.query(receiver, "containing(_:)")
            let predicate = try Boxing.host(
                args.first ?? .void, as: Predicate.self, named: "NSPredicate", "containing(_:)")
            return Boxing.value(query.adding(.containing(predicate)))
        }

        interpreter.bridges["func XCUIElementQuery.containing(_:identifier:)"] = .method { receiver, args in
            let query = try Boxing.query(receiver, "containing(_:identifier:)")
            guard args.count > 1 else {
                throw RuntimeError.invalid("containing(_:identifier:) expects two arguments")
            }
            let identifier = try Boxing.string(args[1], "containing(_:identifier:)")
            // The element type is half the filter — `cells.containing(.button,
            // identifier: "delete")` must not also match a row whose delete
            // affordance is a label or an image.
            guard let type = Self.elementType(from: args[0]) else {
                throw RuntimeError.invalid(
                    "containing(_:identifier:) does not recognise "
                        + "\(Boxing.describe(args[0])) as an element type")
            }
            return Boxing.value(query.adding(.containingType(type, identifier: identifier)))
        }

    }

    // MARK: - Reading a query

    private func registerQueryTerminals(into interpreter: Interpreter) {
        interpreter.bridges["var XCUIElementQuery.count"] = .computed { receiver in
            let query = try Boxing.query(receiver, "count")
            do {
                return .int(try await query.candidates().count)
            } catch { throw Boxing.runtimeError(error) }
        }

        interpreter.bridges["var XCUIElementQuery.allElementsBoundByIndex"] = .computed { receiver in
            let query = try Boxing.query(receiver, "allElementsBoundByIndex")
            do {
                let count = try await query.candidates().count
                return .array(
                    (0..<count).map {
                        Boxing.value(ElementBox(query: query, selection: .index($0)))
                    })
            } catch { throw Boxing.runtimeError(error) }
        }

        // `firstMatch` and `element` terminate a chain; on all three receiver
        // types, because `app.firstMatch` is legal XCUI too.
        for receiver in ["XCUIElementQuery", "XCUIApplication"] {
            interpreter.bridges["var \(receiver).firstMatch"] = .computed { value in
                let query = try Boxing.query(value, "\(receiver).firstMatch")
                return Boxing.value(ElementBox(query: query, selection: .first))
            }
        }
        // On an element it is the element itself, not the first of anything —
        // resolving it as a fresh query would silently discard a boundBy index.
        interpreter.bridges["var XCUIElement.firstMatch"] = .computed { value in
            Boxing.value(try Boxing.element(value, "XCUIElement.firstMatch"))
        }
        interpreter.bridges["var XCUIElementQuery.element"] = .computed { value in
            let query = try Boxing.query(value, "element")
            return Boxing.value(ElementBox(query: query, selection: .first))
        }

    }

    // MARK: - Subtree search

    private func registerQueryDescendants(into interpreter: Interpreter) {
        // `descendants(matching: .any)` — 56 of its 59 uses in the corpus are
        // the wildcard, used as "search everything below here". Both spellings
        // open a new stage: relative to the receiver, which is what makes
        // `cell.descendants(matching: .staticText)` mean what it says.
        let methods: [(spelling: String, relation: Relation)] = [
            ("descendants(matching:)", .descendants), ("descendants()", .descendants),
            // No-argument spellings, because the leading-dot `.any` the real
            // idiom uses cannot be evaluated (see registerElementTypeConstants).
            ("children(matching:)", .children), ("children()", .children)
        ]
        for receiver in Self.providerTypes {
            for method in methods {
                let key = "func \(receiver).\(method.spelling)"
                interpreter.bridges[key] = .method { value, args in
                    let query = try Boxing.query(value, key).descending(method.relation)
                    guard let argument = args.first, !Self.isAbsent(argument) else {
                        return Boxing.value(query)
                    }
                    // A type that cannot be resolved must not quietly become "no
                    // filter" — that turns a narrowing query into the whole tree,
                    // and the script then counts or taps something arbitrary.
                    guard let type = Self.elementType(from: argument) else {
                        throw RuntimeError.invalid(
                            "\(method.spelling) does not recognise "
                                + "\(Boxing.describe(argument)) as an element type")
                    }
                    return Boxing.value(type.isAny ? query : query.adding(.type(type)))
                }
            }
        }
    }

    /// Whether an argument slot was genuinely left empty, as opposed to holding
    /// something we failed to understand.
    static func isAbsent(_ value: Value) -> Bool {
        if case .void = value { return true }
        if case .optional(let inner) = value, inner == nil { return true }
        return false
    }

    /// `XCUIElement.ElementType.any` — the written-out spelling of `.any`.
    ///
    /// The leading-dot form is what real tests use, and the interpreter refuses
    /// it: implicit member access needs the parameter's type to resolve against,
    /// and a bridged parameter has no declared type to consult. Registering the
    /// full path at least gives the idiom *a* spelling that runs, and
    /// `descendants()` with no argument covers the wildcard case that accounts
    /// for nearly every real use.
    func registerElementTypeConstants(into interpreter: Interpreter) {
        var caseNames = ["any"]
        for type in ElementType.all {
            let plural = type.query
            if plural.hasSuffix("ies") {
                caseNames.append(plural.dropLast(3) + "y")
            } else if plural.hasSuffix("s") {
                caseNames.append(String(plural.dropLast()))
            } else {
                caseNames.append(plural)
            }
        }
        for caseName in caseNames {
            for typePath in ["XCUIElement.ElementType", "XCUIElementType"] {
                interpreter.bridges["static let \(typePath).\(caseName)"] = .staticValue(
                    .string(caseName))
            }
        }
    }

    /// Turn `.buttons` / `.any` / `"buttons"` into an element type.
    ///
    /// XCUI spells these as `XCUIElement.ElementType` cases whose names are the
    /// singular of the query property (`.staticText` vs `staticTexts`), so both
    /// spellings are accepted — a script pasted from a test uses one and a
    /// script written against this surface will reach for the other.
    static func elementType(from value: Value) -> ElementType? {
        let name: String
        switch value {
            case .string(let text): name = text
            case .enumValue(_, let caseName, _): name = caseName
            case .opaque(_, let any): name = (any as? String) ?? ""
            default: return nil
        }
        if name.isEmpty { return nil }
        if name == "any" { return .any }
        if let exact = ElementType.named(name) { return exact }
        // Singular → plural: `.staticText` → `staticTexts`.
        if let plural = ElementType.named(name + "s") { return plural }
        if name.hasSuffix("y"), let plural = ElementType.named(name.dropLast() + "ies") {
            return plural
        }
        return nil
    }
}
