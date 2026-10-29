import Foundation

/// A window-title filter, as `--title` takes it.
///
/// With a `*` or `?` in it the pattern is a glob that has to match the whole
/// title: `CRATEFLOW*` means "starts with CRATEFLOW". Without one it is a
/// substring, the same as the `mac:App#title` selector, so a plain word does
/// not silently match nothing because the title has a suffix.
///
/// Matching ignores case and treats straight and typographic apostrophes and
/// quotes as one: titles and button labels use ’ where a shell user types '.
public struct TitlePattern: Sendable, CustomStringConvertible {
    public let pattern: String
    private let isGlob: Bool
    private let needle: String

    public init(_ pattern: String) {
        self.pattern = pattern
        isGlob = pattern.contains("*") || pattern.contains("?")
        needle = Self.normalized(pattern)
    }

    public var description: String { pattern }

    public func matches(_ title: String) -> Bool {
        let haystack = Self.normalized(title)
        guard isGlob else { return haystack.contains(needle) }
        return Self.glob(Array(needle), Array(haystack))
    }

    /// Lowercased, with typographic apostrophes and quotes folded to ASCII.
    public static func normalized(_ text: String) -> String {
        var out = text.lowercased()
        for (fancy, plain) in [("\u{2019}", "'"), ("\u{2018}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\"")] {
            out = out.replacingOccurrences(of: fancy, with: plain)
        }
        return out
    }

    /// Whole-string glob match: `*` is any run, `?` any one character.
    private static func glob(_ pattern: [Character], _ text: [Character]) -> Bool {
        var patternIndex = 0
        var textIndex = 0
        var star: Int?
        var resume = 0
        while textIndex < text.count {
            if patternIndex < pattern.count,
                pattern[patternIndex] == "?" || pattern[patternIndex] == text[textIndex] {
                patternIndex += 1
                textIndex += 1
            } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
                star = patternIndex
                resume = textIndex
                patternIndex += 1
            } else if let star {
                patternIndex = star + 1
                resume += 1
                textIndex = resume
            } else {
                return false
            }
        }
        while patternIndex < pattern.count, pattern[patternIndex] == "*" { patternIndex += 1 }
        return patternIndex == pattern.count
    }
}
