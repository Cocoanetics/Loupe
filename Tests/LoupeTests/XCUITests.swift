import Foundation
import LoupeCore
import Testing

@testable import LoupeXCUI

private func node(
    id: String = "n1", role: String, rawRole: String? = nil, label: String? = nil,
    value: String? = nil, identifier: String? = nil, enabled: Bool = true,
    children: [UINode] = []
) -> UINode {
    UINode(
        id: id, role: role, rawRole: rawRole, label: label, value: value,
        identifier: identifier, frame: Frame(x: 0, y: 0, width: 10, height: 10),
        enabled: enabled, focused: false, actions: [], children: children)
}

@Suite("Predicate parsing")
struct PredicateTests {

    @Test("the eight shapes real UI tests actually write")
    func realWorldShapes() throws {
        let button = node(role: "button", label: "Save Draft", identifier: "save.draft")

        #expect(try Predicate.parse(format: "label CONTAINS %@", arguments: ["Save"]).matches(button))
        #expect(try Predicate.parse(format: "label CONTAINS[c] %@", arguments: ["save"]).matches(button))
        #expect(
            try Predicate.parse(format: "identifier CONTAINS %@", arguments: ["draft"])
                .matches(button))
        #expect(
            try Predicate.parse(format: "identifier BEGINSWITH %@", arguments: ["save"])
                .matches(button))
        #expect(try Predicate.parse(format: "label == %@", arguments: ["Save Draft"]).matches(button))
        #expect(try Predicate.parse(format: "isEnabled == true", arguments: []).matches(button))
    }

    @Test("case sensitivity is honoured")
    func caseSensitivity() throws {
        let button = node(role: "button", label: "Save")
        #expect(!(try Predicate.parse(format: "label CONTAINS %@", arguments: ["save"]).matches(button)))
        #expect(try Predicate.parse(format: "label CONTAINS[c] %@", arguments: ["save"]).matches(button))
    }

    @Test("AND requires every term")
    func conjunction() throws {
        let button = node(role: "button", label: "Save Draft", identifier: "save.draft")
        let both = try Predicate.parse(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", arguments: ["save", "Draft"])
        #expect(try both.matches(button))
        let missing = try Predicate.parse(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", arguments: ["save", "Nope"])
        #expect(try !missing.matches(button))
    }

    @Test("OR needs only one term")
    func disjunction() throws {
        let button = node(role: "button", label: "Save")
        let either = try Predicate.parse(
            format: "label == %@ OR label == %@", arguments: ["Nope", "Save"])
        #expect(try either.matches(button))
    }

    @Test("mixing AND with OR is refused rather than guessed at")
    func mixedOperatorsThrow() {
        #expect(throws: (any Error).self) {
            try Predicate.parse(format: "a == %@ AND b == %@ OR c == %@", arguments: ["1", "2", "3"])
        }
    }

    @Test("a format with more specifiers than arguments is an error, not a silent match")
    func missingArguments() {
        #expect(throws: (any Error).self) {
            try Predicate.parse(format: "label CONTAINS %@ AND identifier == %@", arguments: ["x"])
        }
    }

    @Test("an unparseable term names itself")
    func unparseable() {
        #expect(throws: (any Error).self) {
            try Predicate.parse(format: "label", arguments: [])
        }
    }
}

@Suite("Element type vocabulary")
struct ElementTypeTests {

    @Test("every XCUI query provider is present, so nothing dies on an unknown property")
    func vocabularyIsComplete() {
        for name in [
            "buttons", "staticTexts", "textFields", "secureTextFields", "collectionViews",
            "menuItems", "outlines", "popUpButtons", "checkBoxes", "segmentedControls",
            "switches", "radioButtons", "otherElements", "menuBarItems", "windows",
            "navigationBars", "tabBars", "cells", "tables", "images", "links", "sliders"
        ] {
            #expect(ElementType.named(name) != nil, "missing query provider: \(name)")
        }
    }

    @Test("types that cannot be backed explain themselves instead of matching nothing")
    func unavailableTypesCarryReasons() throws {
        for name in ["keyboards", "keys", "pickerWheels", "statusBars", "touchBars"] {
            let type = try #require(ElementType.named(name))
            #expect(type.roles.isEmpty)
            #expect(type.unavailable != nil, "\(name) has no explanation")
        }
    }

    @Test("secure fields are told apart from plain ones on both surfaces")
    func secureFields() throws {
        let secure = try #require(ElementType.named("secureTextFields"))
        let plain = try #require(ElementType.named("textFields"))

        let macSecure = node(role: "textfield", rawRole: "AXSecureTextField")
        let webSecure = node(role: "textfield", rawRole: "input:password")
        let webPlain = node(role: "textfield", rawRole: "input:text")

        #expect(secure.matches(macSecure))
        #expect(secure.matches(webSecure))
        #expect(!secure.matches(webPlain))
        // The broader query still covers all of them.
        #expect(plain.matches(webSecure) && plain.matches(webPlain))
    }

    @Test("singular case names resolve to their plural query")
    func singularNames() {
        #expect(XCUIModule.elementType(from: .string("staticText"))?.query == "staticTexts")
        #expect(XCUIModule.elementType(from: .string("button"))?.query == "buttons")
        #expect(XCUIModule.elementType(from: .string("any"))?.isAny == true)
        #expect(XCUIModule.elementType(from: .string("nonsense")) == nil)
    }
}

@Suite("Keyed subscript ranking")
struct RankingTests {

    @Test("an exact identifier beats an exact label, which beats a substring")
    func rankingOrder() {
        let candidates = [
            node(id: "a", role: "button", label: "Save Draft Now"),
            node(id: "b", role: "button", label: "Save"),
            node(id: "c", role: "button", label: "Other", identifier: "Save")
        ]
        let ranked = QueryBox.ranked(candidates, key: "Save")
        #expect(ranked.map(\.id) == ["c", "b", "a"])
    }

    @Test("non-matching nodes are dropped")
    func dropsNonMatches() {
        let candidates = [
            node(id: "a", role: "button", label: "Cancel"),
            node(id: "b", role: "button", label: "Save")
        ]
        #expect(QueryBox.ranked(candidates, key: "Save").map(\.id) == ["b"])
    }

    @Test("ties keep document order, so firstMatch is stable")
    func stableTies() {
        let candidates = [
            node(id: "first", role: "cell", label: "Row one"),
            node(id: "second", role: "cell", label: "Row two"),
            node(id: "third", role: "cell", label: "Row three")
        ]
        #expect(QueryBox.ranked(candidates, key: "Row").map(\.id) == ["first", "second", "third"])
    }

    @Test("substring matching finds the merged SwiftUI row that exact matching misses")
    func swiftUIMergedRow() {
        // SwiftUI folds a row's child texts into one element, so the label is
        // the whole row rather than the phrase the test asks for.
        let candidates = [node(id: "row", role: "cell", label: "Build failed · 3m ago")]
        #expect(QueryBox.ranked(candidates, key: "Build failed").map(\.id) == ["row"])
    }
}

@Suite("Divergences are documented")
struct DivergenceTests {

    @Test("the list is non-empty and mentions the ones that bite")
    func divergencesListed() {
        let all = XCUIModule.divergences.joined(separator: "\n")
        #expect(!XCUIModule.divergences.isEmpty)
        #expect(all.contains("tap() and click()"))
        #expect(all.contains("launchEnvironment"))
        #expect(all.contains("orFailure"))
    }
}

@Suite("Predicate structure comes from the format, not the values")
struct PredicateStructureTests {

    @Test("a value containing AND does not split the predicate")
    func valueContainingAnd() throws {
        let button = node(role: "button", label: "Search AND Replace")
        let predicate = try Predicate.parse(
            format: "label == %@", arguments: ["Search AND Replace"])
        #expect(predicate.terms.count == 1)
        #expect(try predicate.matches(button))
    }

    @Test("a value containing an operator name is not mistaken for the operator")
    func valueContainingOperatorName() throws {
        // "Like" contains the LIKE operator. Scanning the whole term for the
        // longest operator token used to split here, leaving an empty value that
        // matched every element.
        let like = node(role: "button", label: "Like")
        let other = node(role: "button", label: "Delete Account")
        let predicate = try Predicate.parse(format: "label == %@", arguments: ["Like"])
        #expect(try predicate.matches(like))
        #expect(try !predicate.matches(other))
    }

    @Test("an unmodelled key fails loudly instead of comparing against nothing")
    func unknownKeyThrows() {
        #expect(throws: (any Error).self) {
            let button = node(role: "button", label: "Save")
            _ = try Predicate.parse(format: "hasKeyboardFocus == true", arguments: [])
                .matches(button)
        }
    }

    @Test("too many arguments is an error rather than a silent drop")
    func surplusArguments() {
        #expect(throws: (any Error).self) {
            try Predicate.parse(format: "label == %@", arguments: ["a", "b"])
        }
    }

    @Test("a doubled percent is a literal, not a substitution")
    func doubledPercent() throws {
        let node = node(role: "text", label: "100% done")
        #expect(try Predicate.parse(format: "label == 100%% done", arguments: []).matches(node))
    }
}

@Suite("Keyed subscript never matches internal handles")
struct HandleLeakTests {

    @Test("a key that happens to be a substring of a node handle does not match")
    func handlesAreNotSearchable() {
        // Web handles look like g2n4, macOS ones like w0/g2/b5. Letting them
        // through means buttons["n"] silently matches — and then taps — whatever
        // came first.
        let candidates = [
            node(id: "g2n2", role: "button", label: "Save"),
            node(id: "g2n4", role: "button", label: "Quit")
        ]
        #expect(QueryBox.ranked(candidates, key: "n").isEmpty)
        #expect(QueryBox.ranked(candidates, key: "g2n2").isEmpty)
        #expect(QueryBox.ranked(candidates, key: "Save").map(\.id) == ["g2n2"])
    }
}

@Suite("Query chains descend instead of intersecting")
struct ChainingTests {

    /// Two cards, each holding a button and a label — the shape every real
    /// "find the button inside this row" query is written against.
    private func cards() -> ResolvedTree {
        let cardA = UINode(
            id: "a", role: "group", rawRole: "group", label: "Card A", value: nil,
            identifier: nil, frame: Frame(x: 0, y: 0, width: 10, height: 10),
            enabled: true, focused: false, actions: [],
            children: [
                node(id: "a-btn", role: "button", label: "Open"),
                node(id: "a-txt", role: "text", label: "Item")
            ])
        let cardB = UINode(
            id: "b", role: "group", rawRole: "group", label: "Card B", value: nil,
            identifier: nil, frame: Frame(x: 0, y: 0, width: 10, height: 10),
            enabled: true, focused: false, actions: [],
            children: [
                node(id: "b-btn", role: "button", label: "Open"),
                node(id: "b-txt", role: "text", label: "Item")
            ])
        return ResolvedTree(roots: [cardA, cardB])
    }

    private func app() -> AppBox {
        AppBox(
            target: Target(surface: .web, locator: "about:blank"),
            session: XCUISession())
    }

    @Test("groups.buttons finds the buttons inside the groups, not their intersection")
    func typeChainDescends() throws {
        let groups = try #require(ElementType.named("groups"))
        let buttons = try #require(ElementType.named("buttons"))
        let query = QueryBox(app: app()).queryingType(groups).queryingType(buttons)
        #expect(try query.candidates(in: cards()).map(\.id) == ["a-btn", "b-btn"])
    }

    @Test("a keyed element scopes what is chained off it")
    func elementScopesItsChain() throws {
        let groups = try #require(ElementType.named("groups"))
        let buttons = try #require(ElementType.named("buttons"))
        let cardA = ElementBox(query: QueryBox(app: app()).queryingType(groups).adding(.key("Card A")))
        let inside = cardA.scopedQuery().queryingType(buttons)
        #expect(try inside.candidates(in: cards()).map(\.id) == ["a-btn"])
    }

    @Test("boundBy survives being chained off")
    func boundByIsNotDropped() throws {
        let groups = try #require(ElementType.named("groups"))
        let buttons = try #require(ElementType.named("buttons"))
        let second = ElementBox(
            query: QueryBox(app: app()).queryingType(groups), selection: .index(1))
        let inside = second.scopedQuery().queryingType(buttons)
        #expect(try inside.candidates(in: cards()).map(\.id) == ["b-btn"])
    }

    @Test("children() is direct children only, descendants() is the whole subtree")
    func childrenVersusDescendants() throws {
        let groups = try #require(ElementType.named("groups"))
        let base = QueryBox(app: app()).queryingType(groups).adding(.key("Card A"))
        let scoped = ElementBox(query: base).scopedQuery()
        #expect(try scoped.descending(.children).candidates(in: cards()).count == 2)
        #expect(try scoped.descending(.descendants).candidates(in: cards()).count == 2)
    }

    @Test("an empty intermediate stage stops the chain rather than restarting it")
    func emptyStageStopsTheChain() throws {
        let groups = try #require(ElementType.named("groups"))
        let buttons = try #require(ElementType.named("buttons"))
        let missing = QueryBox(app: app()).queryingType(groups).adding(.key("No Such Card"))
        let inside = ElementBox(query: missing).scopedQuery().queryingType(buttons)
        #expect(try inside.candidates(in: cards()).isEmpty)
    }
}
