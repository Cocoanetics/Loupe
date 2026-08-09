import Foundation
import XCTest

/// Turns an `XCUIElementSnapshot` into the shape Loupe's `UINode` decodes.
///
/// The snapshot is the whole reason for the bridge: it is the same tree XCUI
/// itself matches against, with real nesting, device-point frames and element
/// types — none of which survive the accessibility route.
@MainActor
enum Tree {

    static func node(of app: XCUIApplication) throws -> [String: Any] {
        node(of: try app.snapshot(), path: "e")
    }

    /// - Parameter path: the element's position in the tree, used as its handle.
    ///   Index-based rather than anything semantic, because it has to survive
    ///   being sent to the host and quoted back — and, like every Loupe handle,
    ///   it is only valid until the next describe.
    private static func node(of snapshot: XCUIElementSnapshot, path: String) -> [String: Any] {
        let frame = snapshot.frame
        var node: [String: Any] = [
            "id": path,
            "role": role(for: snapshot.elementType),
            "rawRole": String(describing: snapshot.elementType),
            "enabled": snapshot.isEnabled,
            "focused": snapshot.hasFocus,
            "actions": actions(for: snapshot),
            "frame": [
                "x": frame.origin.x, "y": frame.origin.y,
                "width": frame.size.width, "height": frame.size.height
            ]
        ]
        if !snapshot.label.isEmpty { node["label"] = snapshot.label }
        if !snapshot.identifier.isEmpty { node["identifier"] = snapshot.identifier }
        if let value = snapshot.value, !"\(value)".isEmpty { node["value"] = "\(value)" }
        // `isSelected` has no UINode field of its own; it rides along on the
        // focus flag, which is the closest thing Loupe models.
        if snapshot.isSelected { node["focused"] = true }

        let children = snapshot.children.enumerated().map { index, child in
            self.node(of: child, path: "\(path)/\(index)")
        }
        if !children.isEmpty { node["children"] = children }
        return node
    }

    /// What the element can plausibly be asked to do. The host uses this to
    /// decide whether an element is worth offering, exactly as it does for the
    /// macOS and web surfaces.
    private static func actions(for snapshot: XCUIElementSnapshot) -> [String] {
        guard snapshot.isEnabled else { return [] }
        switch snapshot.elementType {
            case .button, .link, .cell, .menuItem, .tab, .toolbarButton, .radioButton,
                 .checkBox, .switch, .staticText, .image, .icon, .key, .keyboard:
                return ["press"]
            case .textField, .secureTextField, .searchField, .textView:
                return ["press", "setValue"]
            case .slider, .stepper, .pickerWheel, .segmentedControl:
                return ["press", "adjust"]
            default:
                return []
        }
    }

    /// XCUI's element types collapsed onto the fifteen roles Loupe normalizes
    /// every hierarchy down to, so a `sim:` tree reads like a `mac:` one.
    private static func role(for type: XCUIElement.ElementType) -> String {
        switch type {
            case .button, .toolbarButton, .popUpButton, .menuButton, .disclosureTriangle,
                 .tab, .key:
                return "button"
            case .radioButton: return "radio"
            case .checkBox, .switch, .toggle: return "checkbox"
            case .link: return "link"
            case .staticText: return "text"
            case .textField, .secureTextField, .searchField, .comboBox, .datePicker, .textView:
                return "textfield"
            case .image, .icon: return "image"
            case .window, .sheet, .alert, .dialog: return "window"
            case .menu, .menuBar: return "menu"
            case .menuItem, .menuBarItem: return "menuitem"
            case .table, .collectionView, .outline, .scrollView, .grid, .pickerWheel, .picker:
                return "list"
            case .cell, .tableRow, .outlineRow, .tableColumn: return "cell"
            case .slider: return "slider"
            case .group, .navigationBar, .tabBar, .tabGroup, .toolbar, .statusBar, .layoutArea,
                 .splitGroup, .drawer, .popover, .radioGroup, .segmentedControl, .other:
                return type == .other ? "other" : "group"
            default:
                return "other"
        }
    }
}
