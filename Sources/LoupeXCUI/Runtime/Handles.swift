import Foundation
import LoupeKit

/// The host object behind a script's `XCUIApplication`.
///
/// A class, not a struct, because XCUI's is a reference type and scripts rely on
/// it: `app.launchEnvironment["KEY"] = …` in one helper has to be visible to the
/// `app.launch()` in another.
final class AppBox: @unchecked Sendable {
    /// Where the app lives: a device, a page, a session.
    let target: Target
    /// Which app, when the target alone does not say.
    ///
    /// `mac:Safari` names both at once, but `sim:booted` names only the device —
    /// an iOS app is identified by bundle id *within* it. Keeping the two apart
    /// is what lets `XCUIApplication(bundleIdentifier:)` mean the same thing on
    /// both surfaces.
    let bundleID: String?
    let session: XCUISession
    var launchEnvironment: [String: String] = [:]
    var launchArguments: [String] = []
    /// Whether `launch()` has run, so `state` can answer without probing.
    var didLaunch = false

    init(target: Target, bundleID: String? = nil, session: XCUISession) {
        self.target = target
        self.bundleID = bundleID
        self.session = session
    }

    func driver() async throws -> any UIDriver {
        try await session.driver(for: target)
    }
}

/// One narrowing step within a stage.
enum QueryFilter: Sendable {
    /// `app.buttons`, `.staticTexts` — restrict to an element type.
    case type(ElementType)
    /// `query["Save"]` — XCUI's keyed subscript: identifier or label.
    case key(String)
    /// `matching(identifier:)`
    case identifier(String)
    /// `matching(predicate)`
    case predicate(Predicate)
    /// `containing(predicate)` — keep nodes with a matching descendant.
    case containing(Predicate)
    /// `containing(.button, identifier:)` — the typed form, where the element
    /// type is half the filter and dropping it matches rows whose affordance is
    /// a label or an image rather than a button.
    case containingType(ElementType, identifier: String)
}

/// How a stage reaches the nodes it filters.
enum Relation: Sendable {
    /// The first stage: everything in the tree, roots included.
    case wholeTree
    /// `element.buttons`, `query.descendants(matching:)` — the subtree below
    /// each match of the previous stage, excluding the match itself.
    case descendants
    /// `children(matching:)` — direct children only.
    case children
}

/// One link of a query chain: reach some nodes, narrow them, optionally pick one.
///
/// XCUI queries are relative — `app.tables.cells` means cells *inside* tables,
/// not "things that are both a table and a cell". Modelling a query as a flat
/// list of filters over one flattened tree cannot express that, and quietly
/// answers the intersection instead: every chain between two different element
/// types comes back empty. Stages are what make the chain a descent.
struct QueryStage: Sendable {
    var relation: Relation
    var filters: [QueryFilter] = []
    /// Set when an element terminated this stage — `element(boundBy: 2).buttons`
    /// has to narrow to row 2 *before* descending into it.
    var selection: Selection?

    var isEmpty: Bool { filters.isEmpty && selection == nil }
}

/// The host object behind `XCUIElementQuery`.
final class QueryBox: @unchecked Sendable {
    let app: AppBox
    let stages: [QueryStage]

    init(app: AppBox, stages: [QueryStage] = [QueryStage(relation: .wholeTree)]) {
        self.app = app
        self.stages = stages.isEmpty ? [QueryStage(relation: .wholeTree)] : stages
    }

    /// Narrow the current stage.
    func adding(_ filter: QueryFilter) -> QueryBox {
        var updated = stages
        updated[updated.count - 1].filters.append(filter)
        return QueryBox(app: app, stages: updated)
    }

    /// Start a new stage relative to what the chain has matched so far.
    func descending(_ relation: Relation = .descendants) -> QueryBox {
        QueryBox(app: app, stages: stages + [QueryStage(relation: relation)])
    }

    /// A type query either narrows the current stage or opens a new one.
    ///
    /// `app.buttons` narrows — the first stage is the whole tree and buttons are
    /// what we want from it. `app.groups.buttons` descends, because the receiver
    /// already selected something and XCUI searches *within* it.
    func queryingType(_ type: ElementType) -> QueryBox {
        let base = stages[stages.count - 1].isEmpty ? self : descending()
        return type.isAny ? base : base.adding(.type(type))
    }

    /// How the chain reads back, for error messages: `groups["Card A"].buttons`.
    var description: String {
        var parts: [String] = []
        for stage in stages {
            var text = ""
            for filter in stage.filters {
                switch filter {
                    case .type(let type): text += text.isEmpty ? type.query : ".\(type.query)"
                    case .key(let key): text += "[\"\(key)\"]"
                    case .identifier(let value): text += ".matching(identifier: \"\(value)\")"
                    case .predicate(let predicate): text += ".matching(\(predicate.source))"
                    case .containing(let predicate): text += ".containing(\(predicate.source))"
                    case .containingType(let type, let identifier):
                        text += ".containing(.\(type.query), identifier: \"\(identifier)\")"
                }
            }
            if case .children = stage.relation, text.isEmpty { text = "children()" }
            if case .index(let index) = stage.selection { text += ".element(boundBy: \(index))" }
            if !text.isEmpty { parts.append(text) }
        }
        return parts.isEmpty ? "descendants()" : parts.joined(separator: ".")
    }
}

/// Which of a query's matches an element refers to.
enum Selection: Sendable {
    /// `query.firstMatch`, and the implicit selection of `query["x"]`.
    case first
    /// `query.element(boundBy: n)`
    case index(Int)
}

/// The host object behind `XCUIElement`.
final class ElementBox: @unchecked Sendable {
    let query: QueryBox
    let selection: Selection

    init(query: QueryBox, selection: Selection = .first) {
        self.query = query
        self.selection = selection
    }

    var app: AppBox { query.app }

    /// This element as a query chain, with the selection baked into the last
    /// stage so anything chained off it searches inside *this* element only.
    ///
    /// Dropping the selection here is how `cells.element(boundBy: 2).buttons`
    /// silently becomes `cells.buttons`, which is a different set entirely.
    func scopedQuery() -> QueryBox {
        var stages = query.stages
        stages[stages.count - 1].selection = selection
        return QueryBox(app: app, stages: stages)
    }

    var description: String {
        switch selection {
            case .first: return query.description
            case .index(let index): return "\(query.description).element(boundBy: \(index))"
        }
    }
}

/// The host object behind `XCUIScreenshot`.
final class ScreenshotBox: @unchecked Sendable {
    let png: Data
    init(png: Data) { self.png = png }
}
