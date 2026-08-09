import Foundation
import LoupeKit
import SwiftScriptInterpreter

/// The XCUITest API, backed by Loupe's drivers.
///
/// Registered under the import name `XCUIAutomation`, which is the whole trick:
/// `registerOnImport` keys on the import name as a plain string and never
/// resolves a real module, so one unmodified file gets Apple's framework when it
/// is compiled into a UI-test target and this when it is interpreted. There is
/// no shim to opt into and no conditional import — the source is the same
/// source.
///
/// What it is not: an emulator of `testmanagerd`. XCUI's real implementation
/// throws "Device is not configured for UI testing" the moment it is
/// constructed outside a UI-test bundle, so nothing here can be Apple's code.
/// It is a faithful *surface* over an accessibility tree, which means some of
/// the API cannot be honoured — see ``XCUIModule/divergences``.
public struct XCUIModule: BuiltinModule {

    public let name = "LoupeXCUI"
    let session: XCUISession
    /// Where a bare `XCUIApplication()` with no argument points.
    let defaultTarget: Target?

    public init(session: XCUISession, defaultTarget: Target? = nil) {
        self.session = session
        self.defaultTarget = defaultTarget
    }

    public func register(into interpreter: Interpreter) {
        registerApplication(into: interpreter)
        registerQueryProviders(into: interpreter)
        registerQuery(into: interpreter)
        registerElement(into: interpreter)
        registerSupport(into: interpreter)
        registerEvidence(into: interpreter)
    }

    /// The receivers that are query providers in XCUI: an application is an
    /// element, an element is a provider, and so is a query.
    static let providerTypes = ["XCUIApplication", "XCUIElement", "XCUIElementQuery"]

    /// Every place this surface knowingly departs from Apple's, so the list
    /// lives in one place rather than scattered across doc comments.
    public static let divergences: [String] = [
        "tap() and click() are the same verb — an accessibility tree has one notion of activation.",
        """
        Activation goes through AX, so the app is never brought forward and \
        nothing moves on screen.
        """,
        """
        launch() attaches to a running app rather than starting a fresh one; \
        launchEnvironment and launchArguments only apply when Loupe starts the \
        process itself.
        """,
        """
        The keyed subscript also accepts a substring of the label, ranked below \
        every exact match, because SwiftUI merges a row's texts into one element. \
        A very short key can therefore match something XCUI would not.
        """,
        """
        waitForExistence(timeout:) gains an orFailure: argument, so a login can \
        fail on the error label instead of burning the timeout.
        """,
        """
        rightClick(), doubleTap() and press(forDuration:) are unavailable — the \
        accessibility layer has no way to express them.
        """,
        """
        Element type queries that only exist on iOS (keyboards, pickerWheels, \
        statusBars) report why they cannot be satisfied rather than silently \
        matching nothing.
        """,
        """
        isSelected reports focus, and isHittable reports having a non-empty \
        frame; XCUI computes both from a real hit test.
        """,
        """
        XCUIElement.frame is a CGRect-shaped value with minX/minY/width/height, \
        not a real CGRect.
        """
    ]
}

// MARK: - Query providers

extension XCUIModule {

    /// `app.buttons`, `element.staticTexts`, `query.cells` — 80-odd properties
    /// across three receiver types, all the same shape.
    ///
    /// Registered from the table rather than written out, because the only thing
    /// that varies is which roles satisfy them, and a hand-written copy of each
    /// would be 240 near-identical closures waiting to drift.
    fileprivate func registerQueryProviders(into interpreter: Interpreter) {
        for type in ElementType.all {
            for receiver in Self.providerTypes {
                interpreter.bridges["var \(receiver).\(type.query)"] = .computed { value in
                    let query = try Boxing.query(value, "\(receiver).\(type.query)")
                    return Boxing.value(query.queryingType(type))
                }
            }
        }
    }
}
