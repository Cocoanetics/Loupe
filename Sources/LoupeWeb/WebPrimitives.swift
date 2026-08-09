import AppKit
import Foundation
import LoupeCore
import WebKit

// The two primitives everything else in this driver is built from — take a
// picture, run some JavaScript — plus the error mapping that makes their
// failures actionable.

// MARK: - Primitives

/// A rendered snapshot plus the geometry needed to report it honestly.
struct SnapshotResult: Sendable {
    var png: Data
    var pixelWidth: Int
    var pixelHeight: Int
    /// What WebKit considered the point size — the snapshot rect, or `snapshotWidth`
    /// when one was requested.
    var pointSize: CGSize
}

/// `takeSnapshot`, bridged.
///
/// Everything that is not `Sendable` (the `NSImage`, the `CGImage`) is consumed
/// inside the completion handler so only bytes cross back.
///
/// Geometry, measured rather than assumed: the returned image has
/// `pixels = points × window.backingScaleFactor`, where `points` is the snapshot
/// rect's size, or `snapshotWidth` (and the proportional height) when set. So to
/// hit a requested scale S on a display of backing scale D, ask for
/// `snapshotWidth = cssWidth × S / D`. The caller still measures the result and
/// reports what it actually got.
@MainActor
func loupeSnapshot(_ webView: WKWebView, rect: CGRect?, snapshotWidth: Double?) async throws
    -> SnapshotResult {
    let config = WKSnapshotConfiguration()
    // Without this the snapshot can come from a stale layer and quietly show the
    // page as it was before the last action.
    config.afterScreenUpdates = true
    if let rect { config.rect = rect }
    if let snapshotWidth, snapshotWidth > 0 {
        config.snapshotWidth = NSNumber(value: snapshotWidth)
    }
    return try await withCheckedThrowingContinuation { continuation in
        webView.takeSnapshot(with: config) { image, error in
            if let error {
                continuation.resume(
                    throwing: LoupeError.failed("snapshot failed: \(error.localizedDescription)"))
                return
            }
            guard let image,
                let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else {
                continuation.resume(throwing: LoupeError.failed("snapshot produced no image"))
                return
            }
            do {
                continuation.resume(
                    returning: SnapshotResult(
                        png: try ImageOps.encode(cgImage),
                        pixelWidth: cgImage.width,
                        pixelHeight: cgImage.height,
                        pointSize: image.size))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// `evaluateJavaScript`, bridged, returning the result rendered as a string.
///
/// The value is stringified inside the completion handler for the same reason as
/// above, and because the JS↔ObjC bridge only carries a handful of types: every
/// script this driver ships returns a JSON *string* precisely so nothing is ever
/// lost on the way back.
@MainActor
func loupeEvaluate(_ webView: WKWebView, _ source: String) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
        webView.evaluateJavaScript(source) { value, error in
            if let error {
                continuation.resume(throwing: loupeJavaScriptError(error))
                return
            }
            continuation.resume(returning: stringify(value))
        }
    }
}

/// `callAsyncJavaScript`, bridged. Used as the fallback path for caller-supplied
/// `evaluate` expressions whose result the plain bridge refuses (a Promise, a DOM
/// node, an object graph).
@MainActor
func loupeCallAsync(_ webView: WKWebView, body: String, arguments: [String: Any]) async throws
    -> String {
    try await withCheckedThrowingContinuation { continuation in
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
            switch result {
                case .success(let value): continuation.resume(returning: stringify(value))
                case .failure(let error): continuation.resume(throwing: loupeJavaScriptError(error))
            }
        }
    }
}

/// Render a bridged JS value as a string without losing the distinction between
/// `null`, `undefined` and an empty string.
private func stringify(_ value: Any?) -> String {
    switch value {
        case .none: return "undefined"
        case let string as String: return string
        case is NSNull: return "null"
        case let number as NSNumber: return number.stringValue
        case let some?:
            // Sorted keys so the same object always stringifies the same way, which
            // is what makes an `evaluate` result usable in a before/after comparison.
            if JSONSerialization.isValidJSONObject(some),
                let data = try? JSONSerialization.data(withJSONObject: some, options: [.sortedKeys]),
                let json = String(bytes: data, encoding: .utf8) {
                return json
            }
            return String(describing: some)
    }
}

/// Thrown when the JS↔ObjC bridge refuses the result type (a Promise, a DOM
/// node, a function, a cyclic object).
///
/// A distinct type rather than a `LoupeError` case so the `evaluate` verb can
/// recognise it and retry through `callAsyncJavaScript`, which can await a
/// promise and serialize in-page. Every script this driver ships returns a
/// string, so this only ever escapes for caller-supplied expressions.
struct UnsupportedJSResultType: Error {}

/// Map a WebKit JS error onto something a caller can act on.
private func loupeJavaScriptError(_ error: Error) -> Error {
    let nsError = error as NSError
    guard nsError.domain == WKErrorDomain else {
        return LoupeError.failed("JavaScript failed: \(error.localizedDescription)")
    }
    switch nsError.code {
        case WKError.javaScriptExceptionOccurred.rawValue:
            let message =
                (nsError.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? error.localizedDescription
            let line = nsError.userInfo["WKJavaScriptExceptionLineNumber"] as? Int
            return LoupeError.failed("JavaScript threw: \(message)" + (line.map { " (line \($0))" } ?? ""))
        case WKError.javaScriptResultTypeIsUnsupported.rawValue:
            return UnsupportedJSResultType()
        case WKError.webContentProcessTerminated.rawValue:
            return LoupeError.failed("the web content process crashed while running the script")
        default:
            return LoupeError.failed("JavaScript failed: \(error.localizedDescription)")
    }
}
