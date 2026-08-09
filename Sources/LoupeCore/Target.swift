import Foundation

/// Which surface a target lives on.
public enum Surface: String, Codable, Sendable, CaseIterable {
    case web
    case mac
    case sim
    /// A driver held open in its own process, addressed as `@name`.
    case live
}

/// A parsed target reference.
///
/// The string form is deliberately URI-ish and uniform across surfaces, so one
/// `--target` flag serves the whole tool and an agent only has to learn one
/// shape:
///
/// ```
/// web:https://example.com        an offscreen web view at a URL
/// https://example.com            (bare URLs imply web:)
/// mac:Safari                     frontmost window of an app, by name or bundle id
/// mac:Safari#2                   that app's window at index 2
/// mac:pid:4711                   by process id
/// sim:booted                     the booted simulator
/// sim:iPhone 17 Pro              by device name
/// sim:6805ED2E-71F6-…            by udid
/// ```
public struct Target: Codable, Hashable, Sendable, CustomStringConvertible {
    public var surface: Surface
    /// Everything after the scheme: a URL, app name/bundle id, udid, …
    public var locator: String
    /// Window index for `mac:` targets (`#2`), nil meaning "frontmost".
    public var windowIndex: Int?
    /// Window title substring for `mac:` targets (`#Health Dashboard`).
    ///
    /// Worth preferring over an index: indices are not stable. A transient panel
    /// — a password-autofill popup, a sheet — becomes window #0 and silently
    /// shifts everything, and accessibility only lists windows on the current
    /// Space, so a window can leave the list entirely.
    public var windowTitle: String?

    public init(
        surface: Surface, locator: String, windowIndex: Int? = nil, windowTitle: String? = nil
    ) {
        self.surface = surface
        self.locator = locator
        self.windowIndex = windowIndex
        self.windowTitle = windowTitle
    }

    public var description: String {
        if surface == .live { return "@\(locator)" }
        var text = "\(surface.rawValue):\(locator)"
        if let windowIndex {
            text += "#\(windowIndex)"
        } else if let windowTitle {
            text += "#\(windowTitle)"
        }
        return text
    }

    public static func parse(_ raw: String) throws -> Target {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LoupeError.targetNotFound("empty target")
        }

        // `@name` addresses a live session (see LiveSession).
        if trimmed.hasPrefix("@") {
            let name = String(trimmed.dropFirst())
            guard !name.isEmpty else { throw LoupeError.targetNotFound("@ with no session name") }
            return Target(surface: .live, locator: name)
        }

        // Bare URLs and file paths to HTML are web targets.
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            || trimmed.hasPrefix("file://") {
            return Target(surface: .web, locator: trimmed)
        }

        guard let colon = trimmed.firstIndex(of: ":"),
            let surface = Surface(rawValue: String(trimmed[trimmed.startIndex..<colon]).lowercased())
        else {
            throw LoupeError.targetNotFound(
                "\(trimmed) — expected web:, mac: or sim: (or a bare http(s) URL)")
        }

        var locator = String(trimmed[trimmed.index(after: colon)...])
        var windowIndex: Int?
        var windowTitle: String?

        // `#…` window selector, only meaningful for mac targets. A number is an
        // index; anything else is a title substring. Guard against eating a URL
        // fragment.
        if surface == .mac, let hash = locator.lastIndex(of: "#") {
            let selector = String(locator[locator.index(after: hash)...])
            if !selector.isEmpty {
                if let idx = Int(selector) { windowIndex = idx } else { windowTitle = selector }
                locator = String(locator[locator.startIndex..<hash])
            }
        }

        locator = locator.trimmingCharacters(in: .whitespaces)
        guard !locator.isEmpty else {
            throw LoupeError.targetNotFound("\(trimmed) — missing locator after \(surface.rawValue):")
        }
        return Target(surface: surface, locator: locator, windowIndex: windowIndex, windowTitle: windowTitle)
    }
}
