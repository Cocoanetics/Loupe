import ApplicationServices
import Foundation

/// Normalization of `AXRole` into the vocabulary of ``UINode/role``.
///
/// Both directions are lookup tables rather than `switch` statements: they are
/// data, they are read far more often than they are changed, and a table makes
/// "which AX roles end up as `button`?" a single grep.
enum RoleMap {
    static func normalize(_ axRole: String) -> String {
        normalizedRoles[axRole] ?? "other"
    }

    /// One-letter tag used in node ids, so `w0/g2/b5` stays readable.
    static func idTag(for normalizedRole: String) -> String {
        idTags[normalizedRole] ?? "x"
    }

    private static let normalizedRoles: [String: String] = [
        kAXButtonRole: "button",
        kAXPopUpButtonRole: "button",
        kAXMenuButtonRole: "button",
        kAXRadioButtonRole: "button",
        kAXDisclosureTriangleRole: "button",
        // AXLink has no constant in AXRoleConstants.h even though WebKit and
        // AppKit both emit it.
        "AXLink": "link",
        kAXStaticTextRole: "text",
        kAXHeadingRole: "text",
        kAXTextFieldRole: "textfield",
        kAXTextAreaRole: "textfield",
        kAXComboBoxRole: "textfield",
        kAXCheckBoxRole: "checkbox",
        kAXMenuItemRole: "menuitem",
        kAXMenuBarItemRole: "menuitem",
        kAXMenuRole: "menu",
        kAXMenuBarRole: "menu",
        kAXWindowRole: "window",
        kAXSheetRole: "window",
        kAXDrawerRole: "window",
        kAXImageRole: "image",
        kAXListRole: "list",
        kAXTableRole: "list",
        kAXOutlineRole: "list",
        kAXBrowserRole: "list",
        kAXRowRole: "cell",
        kAXCellRole: "cell",
        kAXColumnRole: "cell",
        kAXGroupRole: "group",
        kAXSplitGroupRole: "group",
        kAXTabGroupRole: "group",
        kAXScrollAreaRole: "group",
        kAXToolbarRole: "group",
        kAXLayoutAreaRole: "group",
        kAXPopoverRole: "group"
    ]

    private static let idTags: [String: String] = [
        "button": "b",
        "link": "a",
        "text": "t",
        "textfield": "f",
        "checkbox": "k",
        "menuitem": "i",
        "menu": "u",
        "window": "w",
        "image": "p",
        "list": "l",
        "cell": "c",
        "group": "g"
    ]
}
