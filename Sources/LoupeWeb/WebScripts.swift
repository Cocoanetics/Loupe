import Foundation

/// The JavaScript this driver injects. What comes back is a ``ScriptEnvelope``.
///
/// Every script is one self-contained IIFE that returns a JSON *string*. Two
/// reasons for the shape:
///
/// * `evaluateJavaScript` returns the script's completion value, and only a
///   handful of types survive the bridge. A string always does, so a JSON string
///   is the one encoding that never loses fidelity (objects with `undefined`,
///   NaN, DOM nodes and cyclic references all fail the default bridging).
/// * A bare `const` at the top level would be a redeclaration error on the second
///   call, because `evaluateJavaScript` evaluates in the page's *global* scope.
///   Wrapping everything in a function expression keeps repeated calls clean and
///   leaves no globals behind except the one deliberate `window.__loupe` handle
///   counter.
enum WebScripts {

    // MARK: - Building blocks

    /// JS string literal for an arbitrary Swift string.
    ///
    /// Hand-rolled rather than routed through `JSONSerialization` so it cannot
    /// throw and so U+2028/U+2029 are escaped — those are legal in JSON but were
    /// line terminators in JavaScript before ES2019, and a page's own script tags
    /// are not the only thing that has to survive here.
    static func literal(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case "\u{2028}": out += "\\u2028"
                case "\u{2029}": out += "\\u2029"
                default:
                    if scalar.value < 0x20 {
                        out += String(format: "\\u%04x", scalar.value)
                    } else {
                        out.unicodeScalars.append(scalar)
                    }
            }
        }
        return out + "\""
    }

    static func literal(_ string: String?) -> String {
        string.map { literal($0) } ?? "null"
    }

    /// Wrap a body in the IIFE + prelude every script needs.
    static func wrap(_ body: String) -> String {
        "(function(){\n\(prelude)\n\(body)\n})()"
    }
}
