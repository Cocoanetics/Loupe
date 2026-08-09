import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import LoupeCore

/// Hashable box around an `AXUIElement`.
///
/// `AXUIElement` is a CoreFoundation type with no Swift `Hashable` conformance,
/// and two handles to the same UI object compare `CFEqual` without being the
/// same pointer. The tree walk's cycle guard needs set membership, hence the box.
struct AXKey: Hashable {
    let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    static func == (lhs: AXKey, rhs: AXKey) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

/// Thin, non-throwing accessors over the C accessibility API.
///
/// Every getter answers `nil` rather than an error: on a live UI tree a missing
/// attribute is the normal case, not an exceptional one, and the walk would
/// otherwise be 90% error plumbing. The *setters* and action calls do report
/// their `AXError`, because there silence is exactly the trap we are guarding
/// against.
enum AXAPI {
    // MARK: - Reading

    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    /// A `CFTypeRef` reinterpreted as a concrete CoreFoundation type, and only
    /// when it really is one.
    ///
    /// The single place in this package where a CF handle changes type, because
    /// this is exactly where a wrong assumption crashes. Swift refuses to compile
    /// `as?` here — "conditional downcast to CoreFoundation type will always
    /// succeed", with a note telling you to compare `CFGetTypeID` instead — so a
    /// *checked* bridge has to be written by hand. This is that check: the type id
    /// is compared first, and the cast below only ever runs on a value that has
    /// already answered to it.
    private static func checked<T>(_ value: CFTypeRef, _ typeID: CFTypeID, as _: T.Type) -> T? {
        guard CFGetTypeID(value) == typeID else { return nil }
        // Not a lint failure to be worked around: `as?` to a CF type does not
        // compile, and the type id gate above is the guard the compiler asks for.
        // swiftlint:disable:next force_cast
        return (value as! T)
    }

    /// Only genuine strings — used for role, title and identifier, where a
    /// number would be meaningless.
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copy(element, attribute), let string = value as? String,
            !string.isEmpty
        else { return nil }
        return string
    }

    /// Any scalar attribute rendered as text: `AXValue` is a `String` on a text
    /// field, an `Int` on a slider and a `Bool` on a checkbox, and an agent wants
    /// to read all three.
    static func scalarDescription(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copy(element, attribute) else { return nil }
        if let string = value as? String { return string.isEmpty ? nil : string }
        if let number = value as? NSNumber { return number.stringValue }
        if CFGetTypeID(value) == AXValueGetTypeID() { return nil }
        return nil
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = copy(element, attribute) else { return nil }
        // CFBoolean bridges through NSNumber; a plain 0/1 CFNumber is also common.
        return (value as? NSNumber)?.boolValue
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        copy(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    static func windows(_ application: AXUIElement) -> [AXUIElement] {
        copy(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute) else { return nil }
        return checked(value, AXUIElementGetTypeID(), as: AXUIElement.self)
    }

    /// Screen frame in points, top-left origin.
    ///
    /// No flipping is needed: the accessibility API already reports positions in
    /// the top-left-origin global space, unlike `NSScreen`/`NSWindow`.
    static func frame(_ element: AXUIElement) -> Frame? {
        guard let positionBox = axValue(element, kAXPositionAttribute),
            let sizeBox = axValue(element, kAXSizeAttribute)
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionBox, .cgPoint, &point),
            AXValueGetValue(sizeBox, .cgSize, &size)
        else { return nil }
        return Frame(x: point.x, y: point.y, width: size.width, height: size.height)
    }

    /// A `CGSize`-valued attribute, e.g. a scroll area's `AXContentSize`.
    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let box = axValue(element, attribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(box, .cgSize, &size) else { return nil }
        return size
    }

    /// The `AXValue` box an attribute is wrapped in — geometry never comes back
    /// as a plain `CGPoint` or `CGSize`, only as one of these.
    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let value = copy(element, attribute) else { return nil }
        return checked(value, AXValueGetTypeID(), as: AXValue.self)
    }

    /// The actions this element genuinely advertises.
    ///
    /// Never guess from the role: a text area advertises `AXShowMenu` only, while
    /// the scroll area *above* it is the one offering `AXScrollDownByPage`.
    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
            let list = names as? [String]
        else { return [] }
        return list
    }

    static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
        else { return false }
        return settable.boolValue
    }

    // MARK: - Writing

    @discardableResult
    static func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    static func perform(_ element: AXUIElement, _ action: String) -> AXError {
        AXUIElementPerformAction(element, action as CFString)
    }

    /// Hit test in global screen points, top-left origin.
    static func elementAt(_ application: AXUIElement, x: Double, y: Double) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(application, Float(x), Float(y), &hit) == .success
        else { return nil }
        return hit
    }

    // MARK: - Window numbers

    /// The `CGWindowID` behind an accessibility window, via the SPI that
    /// ScreenCaptureKit-based tools have used for a decade.
    ///
    /// Resolved through `dlsym` rather than linked: if the symbol ever
    /// disappears, this degrades to `nil` and the caller falls back to matching
    /// on title and frame instead of failing to build. Getting this right matters
    /// — capturing the *wrong* window would be a silent lie, which is the one
    /// failure mode this package exists to prevent.
    static func windowNumber(_ window: AXUIElement) -> CGWindowID? {
        guard let function = axGetWindow else { return nil }
        var identifier: CGWindowID = 0
        guard function(window, &identifier) == .success, identifier != 0 else { return nil }
        return identifier
    }

    private typealias GetWindowFunction =
        @convention(c) @Sendable (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let axGetWindow: GetWindowFunction? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
            let symbol = dlsym(handle, "_AXUIElementGetWindow")
        else { return nil }
        return unsafeBitCast(symbol, to: GetWindowFunction.self)
    }()

    // MARK: - Diagnostics

    /// Turn an `AXError` into something a caller can act on.
    ///
    /// A table rather than a `switch` because that is what it is: nothing is
    /// computed, and the parenthetical on half the entries — what the error means
    /// *for a background app driven from a CLI* — is the part worth reading.
    static func describe(_ error: AXError) -> String {
        errorDescriptions[error] ?? "AXError(\(error.rawValue))"
    }

    private static let errorDescriptions: [AXError: String] = [
        .success: "success",
        .failure: "AXError.failure (the app refused the request)",
        .illegalArgument: "AXError.illegalArgument",
        .invalidUIElement: "AXError.invalidUIElement (the element is gone — re-describe)",
        .invalidUIElementObserver: "AXError.invalidUIElementObserver",
        .cannotComplete: "AXError.cannotComplete (the app is busy or not responding to accessibility)",
        .attributeUnsupported: "AXError.attributeUnsupported",
        .actionUnsupported: "AXError.actionUnsupported",
        .notificationUnsupported: "AXError.notificationUnsupported",
        .notImplemented: "AXError.notImplemented (the app does not implement the accessibility API here)",
        .notificationAlreadyRegistered: "AXError.notificationAlreadyRegistered",
        .notificationNotRegistered: "AXError.notificationNotRegistered",
        .apiDisabled: "AXError.apiDisabled (accessibility is off for this process)",
        .noValue: "AXError.noValue",
        .parameterizedAttributeUnsupported: "AXError.parameterizedAttributeUnsupported",
        .notEnoughPrecision: "AXError.notEnoughPrecision"
    ]
}
