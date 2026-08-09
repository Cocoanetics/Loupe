import Foundation
import LoupeKit

/// One entry of XCUI's element-type vocabulary, mapped onto what Loupe's
/// describe actually reports.
///
/// XCUI exposes 82 query properties (`buttons`, `staticTexts`, `outlineRows`, …)
/// and Loupe normalizes every hierarchy down to fifteen roles. The mapping is
/// therefore many-to-one and, in places, lossy — `popUpButtons` and
/// `menuButtons` both land on `button` because that is all AX tells us apart.
///
/// Every name in XCUI's vocabulary is present here even when nothing can back
/// it, because the failure has to be *legible*: a script asking for
/// `app.pickerWheels` should be told that picker wheels do not exist on this
/// surface, not that `pickerWheels` is an unknown property.
struct ElementType: Sendable {
    /// The Swift property name, e.g. `secureTextFields`.
    let query: String
    /// Loupe roles that satisfy it. Empty means "not representable here".
    let roles: Set<String>
    /// Extra test against the native role, for the distinctions the platform
    /// keeps but Loupe's normalization drops — a secure field is an
    /// `AXTextField` with a subrole on macOS and an `input:password` on the web,
    /// and by the time it is a `UINode` only `rawRole` still knows.
    ///
    /// A list rather than one string because the two surfaces spell the same
    /// distinction differently, and a query has to work on both.
    let rawRoleMatches: [String]
    /// Why nothing can back this one. Non-nil exactly when `roles` is empty.
    let unavailable: String?

    init(
        _ query: String, _ roles: Set<String>, rawRole: [String] = [],
        unavailable: String? = nil
    ) {
        self.query = query
        self.roles = roles
        self.rawRoleMatches = rawRole
        self.unavailable = unavailable
    }

    /// Does this node belong to the element type?
    ///
    /// AX tokens are matched as substrings, because macOS reports a subrole
    /// glued on (`AXTextField/AXSecureTextField`). Everything else is matched
    /// whole: the web reports a bare tag or ARIA role, and a substring test there
    /// makes `scrollViews` match a `scrollbar`.
    func matches(_ node: UINode) -> Bool {
        if roles.isEmpty { return false }
        guard roles.contains(node.role) else { return false }
        guard !rawRoleMatches.isEmpty else { return true }
        let raw = node.rawRole ?? ""
        return rawRoleMatches.contains { token in
            token.hasPrefix("AX")
                ? raw.localizedCaseInsensitiveContains(token)
                : raw.caseInsensitiveCompare(token) == .orderedSame
        }
    }
}

extension ElementType {

    /// Every query provider XCUI defines, in header order.
    ///
    /// Kept complete rather than trimmed to the ones that map cleanly, so that
    /// pasting a real test in never dies on a missing property — it either works
    /// or says precisely why it cannot.
    static let all: [ElementType] = [
        // — Containers ————————————————————————————————————
        ElementType("touchBars", [], unavailable: "Touch Bar elements are not in the accessibility tree"),
        ElementType("groups", ["group"]),
        ElementType("windows", ["window"]),
        ElementType("sheets", ["window"], rawRole: ["AXSheet"]),
        ElementType("drawers", ["group"], rawRole: ["AXDrawer"]),
        ElementType("alerts", ["window"], rawRole: ["AXDialog", "alertdialog", "alert"]),
        ElementType("dialogs", ["window"], rawRole: ["AXDialog", "dialog"]),

        // — Controls ——————————————————————————————————————
        ElementType("buttons", ["button"]),
        ElementType("radioButtons", ["radio"]),
        ElementType("radioGroups", ["group"], rawRole: ["AXRadioGroup", "radiogroup"]),
        ElementType("checkBoxes", ["checkbox"]),
        ElementType("disclosureTriangles", ["button"], rawRole: ["AXDisclosureTriangle", "summary"]),
        ElementType("popUpButtons", ["button", "list"], rawRole: ["AXPopUpButton", "AXMenuButton", "select"]),
        ElementType("comboBoxes", ["textfield", "list", "group"], rawRole: ["AXComboBox", "combobox"]),
        ElementType("menuButtons", ["button"], rawRole: ["AXMenuButton"]),
        ElementType("toolbarButtons", ["button"]),
        ElementType("popovers", ["group"], rawRole: ["AXPopover"]),

        // — iOS keyboard ——————————————————————————————————
        ElementType("keyboards", [], unavailable: "the software keyboard is only reachable from a UI-test runner"),
        ElementType("keys", [], unavailable: "the software keyboard is only reachable from a UI-test runner"),

        // — Bars ——————————————————————————————————————————
        ElementType("navigationBars", ["group", "other"], rawRole: ["AXNavigation", "nav", "navigation"]),
        ElementType("tabBars", ["group", "other", "list"], rawRole: ["AXTabGroup", "tablist", "tabbar"]),
        ElementType("tabGroups", ["group", "list"], rawRole: ["AXTabGroup", "tablist"]),
        ElementType("toolbars", ["group"], rawRole: ["AXToolbar", "toolbar"]),
        ElementType("statusBars", [], unavailable: "the status bar belongs to the system, not the app"),

        // — Tables and lists ——————————————————————————————
        ElementType("tables", ["group", "list"], rawRole: ["AXTable", "table"]),
        ElementType("tableRows", ["cell"]),
        ElementType("tableColumns", ["cell"], rawRole: ["AXColumn"]),
        ElementType("outlines", ["list", "group"], rawRole: ["AXOutline", "tree", "treegrid"]),
        ElementType("outlineRows", ["cell"]),
        ElementType("disclosedChildRows", ["cell"]),
        ElementType("browsers", ["group"], rawRole: ["AXBrowser"]),
        ElementType("collectionViews", ["list"]),

        // — Indicators ————————————————————————————————————
        ElementType("sliders", ["slider"]),
        ElementType("pageIndicators", [], unavailable: "page indicators expose no distinct accessibility role"),
        ElementType("progressIndicators", ["other"], rawRole: ["AXProgressIndicator", "progress", "meter"]),
        ElementType("activityIndicators", ["other"], rawRole: ["AXBusyIndicator"]),
        ElementType("segmentedControls", ["group"], rawRole: ["AXRadioGroup", "AXSegmentedControl", "radiogroup"]),
        ElementType("pickers", [], unavailable: "UIKit pickers are not in the macOS accessibility tree"),
        ElementType("pickerWheels", [], unavailable: "UIKit picker wheels are not in the macOS accessibility tree"),
        ElementType("switches", ["checkbox"], rawRole: ["AXSwitch", "switch"]),
        ElementType("toggles", ["checkbox"], rawRole: ["AXToggle"]),

        // — Content ———————————————————————————————————————
        ElementType("links", ["link"]),
        ElementType("images", ["image"]),
        ElementType("icons", ["image"]),
        ElementType("searchFields", ["textfield"], rawRole: ["AXSearchField", "input:search"]),
        ElementType("scrollViews", ["group"], rawRole: ["AXScrollArea", "scrollarea"]),
        ElementType("scrollBars", ["other", "group"], rawRole: ["AXScrollBar", "scrollbar"]),
        ElementType("staticTexts", ["text"]),
        ElementType("textFields", ["textfield"]),
        ElementType("secureTextFields", ["textfield"], rawRole: ["AXSecureTextField", "input:password"]),
        ElementType("datePickers", ["textfield"], rawRole: ["AXDateField", "input:date"]),
        ElementType("textViews", ["textfield"], rawRole: ["AXTextArea", "textarea"]),

        // — Menus —————————————————————————————————————————
        ElementType("menus", ["menu"]),
        ElementType("menuItems", ["menuitem"]),
        ElementType("menuBars", ["menu"], rawRole: ["AXMenuBar"]),
        ElementType("menuBarItems", ["menuitem"], rawRole: ["AXMenuBarItem"]),

        // — Layout ————————————————————————————————————————
        ElementType("layoutAreas", ["group"], rawRole: ["LayoutArea"]),
        ElementType("layoutItems", ["other"], rawRole: ["LayoutItem"]),
        ElementType("handles", ["other"], rawRole: ["Handle"]),
        ElementType("splitGroups", ["group"], rawRole: ["SplitGroup"]),
        ElementType("splitters", ["other"], rawRole: ["Splitter"]),
        ElementType("relevanceIndicators", ["other"], rawRole: ["Relevance"]),
        ElementType("rulers", ["other"], rawRole: ["Ruler"]),
        ElementType("rulerMarkers", ["other"], rawRole: ["RulerMarker"]),
        ElementType("grids", ["list", "group"], rawRole: ["AXGrid", "grid"]),
        ElementType("levelIndicators", ["other"], rawRole: ["LevelIndicator"]),
        ElementType("cells", ["cell"]),
        ElementType("helpTags", ["other"], rawRole: ["Help"]),
        ElementType("mattes", ["other"], rawRole: ["Matte"]),
        ElementType("dockItems", ["other"], rawRole: ["DockItem"]),
        ElementType("timelines", ["other"], rawRole: ["Timeline"]),
        ElementType("valueIndicators", ["other"], rawRole: ["ValueIndicator"]),
        ElementType("incrementArrows", ["button"], rawRole: ["IncrementArrow"]),
        ElementType("decrementArrows", ["button"], rawRole: ["DecrementArrow"]),
        ElementType("steppers", ["other"], rawRole: ["Stepper"]),
        ElementType("colorWells", ["other"], rawRole: ["ColorWell"]),
        ElementType("otherElements", ["other"]),
        ElementType("webViews", ["group"], rawRole: ["AXWebArea", "iframe"]),
        ElementType("maps", ["other"], rawRole: ["Map"]),
        ElementType("statusItems", ["menuitem"], rawRole: ["StatusItem"]),
        ElementType("terminals", ["other"], rawRole: ["Terminal"]),
        ElementType("ratingIndicators", ["other"], rawRole: ["Rating"])
    ]

    private static let byQuery: [String: ElementType] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.query, $0) })

    static func named(_ query: String) -> ElementType? { byQuery[query] }

    /// `descendants(matching: .any)` and friends — matches every node.
    static let any = ElementType("any", [])

    /// Whether this is the wildcard, which `matches` cannot express (its role
    /// set is empty, which otherwise means "unavailable").
    var isAny: Bool { query == "any" }
}
