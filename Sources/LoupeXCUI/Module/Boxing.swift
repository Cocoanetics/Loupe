import Foundation
import LoupeKit
import SwiftScriptInterpreter

/// Conversions between the interpreter's `Value` and the host objects behind
/// the XCUI facade.
///
/// SwiftScript's own unboxing helpers are internal to the interpreter, so a
/// module living outside that package writes its own. They are deliberately
/// strict: a bridge that quietly coerces the wrong type turns a script typo
/// into a mysterious non-match ten lines later.
enum Boxing {

    // MARK: - Out of the interpreter

    static func string(_ value: Value, _ context: @autoclosure () -> String) throws -> String {
        if case .string(let text) = value { return text }
        if case .optional(let inner) = value, let inner {
            return try string(inner, context())
        }
        throw RuntimeError.invalid("\(context()) expects a String, got \(describe(value))")
    }

    static func int(_ value: Value, _ context: @autoclosure () -> String) throws -> Int {
        switch value {
            case .int(let number): return number
            case .double(let number): return Int(number)
            default:
                throw RuntimeError.invalid("\(context()) expects an Int, got \(describe(value))")
        }
    }

    static func double(_ value: Value, _ context: @autoclosure () -> String) throws -> Double {
        switch value {
            case .double(let number): return number
            case .int(let number): return Double(number)
            default:
                throw RuntimeError.invalid("\(context()) expects a number, got \(describe(value))")
        }
    }

    static func host<T>(
        _ value: Value, as type: T.Type, named typeName: String,
        _ context: @autoclosure () -> String
    ) throws -> T {
        guard case .opaque(_, let any) = value, let typed = any as? T else {
            throw RuntimeError.invalid(
                "\(context()) expects a \(typeName), got \(describe(value))")
        }
        return typed
    }

    static func app(_ value: Value, _ context: @autoclosure () -> String) throws -> AppBox {
        try host(value, as: AppBox.self, named: "XCUIApplication", context())
    }

    static func query(_ value: Value, _ context: @autoclosure () -> String) throws -> QueryBox {
        // `app.buttons` is a query, but so is `app` itself when a script writes
        // `app.descendants(...)` — XCUIApplication is an element, and elements
        // are query providers too.
        if case .opaque(let typeName, let any) = value {
            if let query = any as? QueryBox { return query }
            // An element's chain, with its selection baked in, so anything
            // queried off it searches inside that one element.
            if let element = any as? ElementBox { return element.scopedQuery() }
            if let app = any as? AppBox { return QueryBox(app: app) }
            throw RuntimeError.invalid(
                "\(context()) expects an XCUIElementQuery, got \(typeName)")
        }
        throw RuntimeError.invalid(
            "\(context()) expects an XCUIElementQuery, got \(describe(value))")
    }

    static func element(_ value: Value, _ context: @autoclosure () -> String) throws -> ElementBox {
        if case .opaque(let typeName, let any) = value {
            if let element = any as? ElementBox { return element }
            // XCUIApplication is itself an element in XCUI.
            if let app = any as? AppBox {
                return ElementBox(query: QueryBox(app: app))
            }
            if let query = any as? QueryBox { return ElementBox(query: query) }
            throw RuntimeError.invalid("\(context()) expects an XCUIElement, got \(typeName)")
        }
        throw RuntimeError.invalid(
            "\(context()) expects an XCUIElement, got \(describe(value))")
    }

    static func bool(_ value: Value, _ context: @autoclosure () -> String) throws -> Bool {
        if case .bool(let flag) = value { return flag }
        throw RuntimeError.invalid("\(context()) expects a Bool, got \(describe(value))")
    }

    // MARK: - Into the interpreter

    static func value(_ app: AppBox) -> Value {
        .opaque(typeName: "XCUIApplication", value: app)
    }
    static func value(_ query: QueryBox) -> Value {
        .opaque(typeName: "XCUIElementQuery", value: query)
    }
    static func value(_ element: ElementBox) -> Value {
        .opaque(typeName: "XCUIElement", value: element)
    }
    static func value(_ screenshot: ScreenshotBox) -> Value {
        .opaque(typeName: "XCUIScreenshot", value: screenshot)
    }
    static func value(_ predicate: Predicate) -> Value {
        .opaque(typeName: "NSPredicate", value: predicate)
    }

    /// XCUI's optional-valued attributes (`value`, `placeholderValue`) as
    /// something `as? String` can still see through.
    static func optionalString(_ text: String?) -> Value {
        guard let text else { return .optional(nil) }
        return .optional(.string(text))
    }

    static func rect(_ frame: Frame?) -> Value {
        let frame = frame ?? Frame(x: 0, y: 0, width: 0, height: 0)
        return .opaque(typeName: "CGRect", value: frame)
    }

    /// Unwrap one level of Optional so a boxed `.optional(.string("x"))`
    /// compares equal to `.string("x")`.
    ///
    /// XCUI's own `value` is `Any?`, so `XCTAssertEqual(field.value, "admin")`
    /// is what a real test writes. Comparing the boxes raw makes every such
    /// assertion fail no matter what is on screen.
    static func lifted(_ value: Value) -> Value {
        if case .optional(let inner) = value { return inner.map(lifted) ?? .void }
        return value
    }

    /// Both the type and the value, because a failed comparison needs both:
    /// `Optional(String("2")) != String("7")` is the case the type alone
    /// explains, and `Int(2) != Int(7)` is the case only the value does.
    static func describe(_ value: Value) -> String {
        switch value {
            case .string(let text): return "String(\"\(text)\")"
            case .int(let n): return "Int(\(n))"
            case .double(let d): return "Double(\(d))"
            case .bool(let flag): return "Bool(\(flag))"
            case .void: return "Void"
            case .array: return "Array"
            case .dict: return "Dictionary"
            case .optional(let inner): return inner.map { "Optional(\(describe($0)))" } ?? "nil"
            case .opaque(let typeName, _): return typeName
            default: return "\(value)"
        }
    }

    /// Turn a Loupe failure into something the script's own error text can show
    /// without leaking a secret that was interpolated into a field.
    static func runtimeError(_ error: any Error) -> RuntimeError {
        if let error = error as? RuntimeError { return error }
        let text = (error as? LoupeError)?.errorDescription ?? error.localizedDescription
        return RuntimeError.invalid(Secrets.redact(text))
    }
}
