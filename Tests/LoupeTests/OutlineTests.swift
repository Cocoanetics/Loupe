import Foundation
import Testing

@testable import LoupeCore

/// The renderer and the disclosure contract.
///
/// Worth having as unit tests rather than something you check by eye against a
/// running app: `[UINode] -> String` is the one part of describe with no live
/// target on the other end, and the two properties most likely to break silently
/// — resolution still seeing the menu bar, and an elision never going unreported
/// — cost nothing to assert and are invisible when they regress.
@Suite("describe: progressive disclosure")
struct OutlineTests {

    private func leaf(_ id: String, _ role: String, label: String? = nil) -> UINode {
        UINode(id: id, role: role, label: label)
    }

    // MARK: The contract resolution depends on

    /// The landmine. `UIDriver.resolve` runs through `describe`, so if collapsing
    /// the menu bar ever became the *type's* default, `press "Quit"` would start
    /// throwing — and worse, the near-miss list would quietly lose menu
    /// candidates, turning "here are three things that nearly match" into
    /// "nothing matches" for an element sitting right there.
    @Test("the default scope expands everything, so resolution is unaffected")
    func defaultScopeIsAll() {
        #expect(DescribeOptions().scope == .all)
        #expect(DescribeOptions.default.scope == .all)
        // The presentation entry points opt in; nothing else should have to.
        #expect(DescribeOptions(scope: .primary).scope == .primary)
    }

    // MARK: Nothing disappears without saying so

    @Test("an elided node reports what it is hiding, and how to see it")
    func elisionNamesTheDrillIn() {
        let node = UINode(
            id: "w0/g0/l0", role: "list", label: "Sidebar",
            elided: Elision(children: 14, reason: .depth))
        let out = Outline.render([node])
        #expect(out.contains("14 children not expanded"))
        #expect(out.contains("depth cap reached"))
        // The handle has to be in the line: an agent that has to invent one is
        // guessing at the single thing it cannot see.
        #expect(out.contains("describe at w0/g0/l0"))
    }

    @Test("one withheld child reads as a child, not 1 children")
    func elisionCountsGrammatically() {
        let out = Outline.render([
            UINode(id: "w0", role: "group", elided: Elision(children: 1, reason: .budget))
        ])
        #expect(out.contains("1 child not expanded"))
        #expect(out.contains("node budget spent"))
    }

    @Test("the census counts what was withheld, not just what was shown")
    func censusReportsWithheld() {
        let tree = UINode(
            id: "w0", role: "window", label: "Main",
            children: [leaf("w0/b0", "button", label: "OK")],
            elided: Elision(children: 40, reason: .collapsed))
        let census = Outline.census([tree])
        #expect(census.contains("2 node(s) shown"))
        #expect(census.contains("40 not expanded"))
    }

    // MARK: The line format agents parse

    @Test("every line ends in the handle act takes")
    func everyLineCarriesItsHandle() {
        let tree = UINode(
            id: "w0", role: "window", label: "Main",
            children: [leaf("w0/b0", "button", label: "Sign In")])
        for line in Outline.render([tree]).split(separator: "\n") {
            #expect(line.hasSuffix("]"), "no handle on: \(line)")
        }
    }

    @Test("state is shown only when it deviates")
    func stateIsShownOnlyWhenItDeviates() {
        let plain = Outline.render([leaf("w0/b0", "button", label: "OK")])
        #expect(!plain.contains("(disabled)"))
        #expect(!plain.contains("(focused)"))

        let odd = UINode(id: "w0/b1", role: "button", label: "No", enabled: false, focused: true)
        let out = Outline.render([odd])
        #expect(out.contains("(disabled)"))
        #expect(out.contains("(focused)"))
    }

    @Test("actions are off by default and complete when asked for")
    func actionsAreOptIn() {
        let node = UINode(
            id: "w0/b0", role: "button", label: "OK", actions: ["AXPress", "AXShowMenu"])
        #expect(!Outline.render([node]).contains("Press"))
        #expect(Outline.render([node], actions: true).contains("{Press,ShowMenu}"))
    }

    /// `AXUIElementCopyActionNames` really does return `AXPress` twice on some
    /// AppKit controls — 12 of them on one window here. Rendering it twice would
    /// read as meaningful.
    @Test("a duplicated action is reported once")
    func duplicateActionsCollapse() {
        #expect(Outline.actionList(["AXPress", "AXPress", "AXShowMenu"]) == "{Press,ShowMenu}")
        #expect(Outline.actionList([]) == nil)
    }

    // MARK: Re-rooting

    @Test("a subtree is found by the handle a previous describe printed")
    func subtreeFoundByHandle() {
        let tree = UINode(
            id: "w0", role: "window",
            children: [
                UINode(
                    id: "w0/g0", role: "group",
                    children: [leaf("w0/g0/b1", "button", label: "Deep")])
            ])
        #expect(tree.subtree(withID: "w0/g0/b1")?.label == "Deep")
        #expect(tree.subtree(withID: "w0/g0")?.children.count == 1)
        #expect(tree.subtree(withID: "nope") == nil)
    }

    // MARK: Drilling in actually advances

    /// The review caught this: for surfaces that cannot start a walk partway
    /// down, the branch was extracted *after* the depth had been spent reaching
    /// it — so drilling into a frontier node returned the same elided node, and
    /// an agent following the printed `describe at …` would repeat it forever.
    @Test("a re-rooted branch is bounded from the branch, not from the root")
    func drillInAdvances() {
        let deep = UINode(
            id: "w0", role: "window",
            children: [
                UINode(
                    id: "w0/g0", role: "group",
                    children: [
                        UINode(
                            id: "w0/g0/l0", role: "list", label: "Sidebar",
                            children: [leaf("w0/g0/l0/c0", "cell", label: "Row")])
                    ])
            ])

        // Bounded from the top, the branch is a dead end that names itself.
        let shallow = deep.limited(toDepth: 2)
        let frontier = shallow.subtree(withID: "w0/g0/l0")
        #expect(frontier?.children.isEmpty == true)
        #expect(frontier?.elided?.children == 1)

        // Bounded from the branch, the same depth buys a level of new content.
        let opened = deep.subtree(withID: "w0/g0/l0")!.limited(toDepth: 2)
        #expect(opened.children.count == 1)
        #expect(opened.children.first?.label == "Row")
        #expect(opened.elided == nil)
    }

    @Test("limiting reports what it cut and leaves a shallow tree alone")
    func limitingIsHonestAndIdempotent() {
        let tree = UINode(
            id: "w0", role: "window",
            children: [leaf("w0/b0", "button", label: "OK")])
        #expect(tree.limited(toDepth: 5) == tree)

        let cut = tree.limited(toDepth: 0)
        #expect(cut.children.isEmpty)
        #expect(cut.elided?.children == 1)
        #expect(cut.elided?.reason == .depth)
    }

    // MARK: The wire form

    /// 88% of nodes on a real tree are leaves, so `"children":[]` alone cost
    /// 1,750 chars of a 33,222-char payload. Omitting a default is only safe if
    /// decoding puts it back.
    @Test("omitted defaults survive a round trip")
    func defaultsRoundTrip() throws {
        let node = UINode(id: "w0/b0", role: "button", label: "OK")
        let data = try JSONEncoder().encode(node)
        let json = String(bytes: data, encoding: .utf8) ?? ""

        #expect(!json.contains("children"))
        #expect(!json.contains("enabled"))
        #expect(!json.contains("focused"))
        #expect(!json.contains("actions"))
        #expect(!json.contains("elided"))

        let back = try JSONDecoder().decode(UINode.self, from: data)
        #expect(back == node)
        #expect(back.enabled)
        #expect(!back.focused)
        #expect(back.children.isEmpty)
    }

    @Test("non-default state is still written")
    func deviationsAreEncoded() throws {
        let node = UINode(
            id: "w0/b0", role: "button", enabled: false, focused: true,
            actions: ["AXPress"], elided: Elision(children: 3, reason: .depth))
        let data = try JSONEncoder().encode(node)
        let back = try JSONDecoder().decode(UINode.self, from: data)
        #expect(back == node)
        #expect(back.elided?.children == 3)
        #expect(back.elided?.reason == .depth)
    }
}
