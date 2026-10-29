import CoreGraphics
import Foundation

/// The largest picture a recording may become, as `--max-size` spells it.
///
/// - `WxH`, e.g. `1280x720`: a literal box, never turned around.
/// - `N`, e.g. `800`: short for `NxN`, so the longest side is at most N.
/// - `720p`, `1080p`, `1440p`, `4k`: a landscape box that turns with the picture,
///   so a portrait capture fits 720×1280, 1080×1920 and so on.
public struct MaxSize: Sendable, Equatable, CustomStringConvertible {
    public var width: Int
    public var height: Int
    /// A preset turns to the picture's orientation; a literal box does not.
    public var followsOrientation: Bool
    /// How it was given, for notes: `720p`, `1280x720`.
    public var description: String

    public init(width: Int, height: Int, followsOrientation: Bool = false, description: String? = nil) {
        self.width = width
        self.height = height
        self.followsOrientation = followsOrientation
        self.description = description ?? "\(width)x\(height)"
    }

    /// The GIF's box when none is given.
    public static let gifDefault = MaxSize(width: 800, height: 800)

    public static let presets: [MaxSize] = [
        preset("720p", 1280, 720), preset("1080p", 1920, 1080), preset("1440p", 2560, 1440),
        preset("4k", 3840, 2160)
    ]

    private static func preset(_ name: String, _ width: Int, _ height: Int) -> MaxSize {
        MaxSize(width: width, height: height, followsOrientation: true, description: name)
    }

    public static func parse(_ text: String) throws -> MaxSize {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let preset = presets.first(where: { $0.description == value }) { return preset }
        let sides = value.split(separator: "x", omittingEmptySubsequences: false)
        let numbers = sides.compactMap { side in Int(side).flatMap { $0 > 0 ? $0 : nil } }
        guard !sides.isEmpty, sides.count <= 2, numbers.count == sides.count else {
            throw MediaError.unreadable(
                "invalid --max-size '\(text)': give WxH (e.g. 1280x720), N for an NxN box (e.g. 800), "
                    + "or one of " + presets.map(\.description).joined(separator: ", "))
        }
        if numbers.count == 1 {
            return MaxSize(width: numbers[0], height: numbers[0], description: "\(numbers[0])")
        }
        return MaxSize(width: numbers[0], height: numbers[1])
    }

    /// `size` scaled down, keeping its shape, to fit the box; both sides even.
    /// Never scaled up: a picture that already fits comes back unchanged.
    public func fit(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        let portrait = followsOrientation && size.height > size.width
        let boxWidth = Double(portrait ? height : width)
        let boxHeight = Double(portrait ? width : height)
        let factor = min(boxWidth / size.width, boxHeight / size.height)
        guard factor < 1 else { return size }
        // The epsilon keeps an exact fit, such as 2560 × 0.5, from flooring to one less.
        func side(_ length: Double) -> Int { max(2, Int(length * factor + 1e-6) & ~1) }
        return CGSize(width: side(size.width), height: side(size.height))
    }
}
