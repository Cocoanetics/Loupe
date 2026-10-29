import CoreGraphics
import Foundation

/// What ``CaptureOptions/region`` is measured in. The origin is always the
/// top-left corner, x to the right and y down.
public enum RegionUnits: String, Codable, CaseIterable, Sendable {
    /// The target's own point space — the one ``UINode/frame`` uses, so an
    /// element's frame can be passed straight back as a region:
    ///
    /// - **Mac window:** global screen points (the accessibility API's space),
    ///   *not* window-relative. Each capture notes the window's screen frame.
    /// - **Simulator:** device screen points.
    /// - **Web:** CSS pixels of the viewport, or of the page for `fullPage`.
    case points
    /// Pixels of the image the same capture would return uncropped, origin at
    /// its top-left — so a rectangle read off a full screenshot works as is.
    case pixels
}

/// A crop as applied, in both spaces.
public struct CaptureCrop: Codable, Hashable, Sendable {
    /// In the target's point space (see ``RegionUnits/points``).
    public var points: Frame
    /// In pixels of the uncropped capture (see ``RegionUnits/pixels``).
    public var pixels: Frame

    public init(points: Frame, pixels: Frame) {
        self.points = points
        self.pixels = pixels
    }

    /// One line for a capture's notes.
    public var note: String {
        String(
            format: "cropped to x=%.0f y=%.0f w=%.0f h=%.0f pt = x=%.0f y=%.0f w=%.0f h=%.0f px "
                + "of the uncropped capture",
            points.x, points.y, points.width, points.height,
            pixels.x, pixels.y, pixels.width, pixels.height)
    }
}

extension CaptureOptions {

    /// ``region`` in the target's point space, for a capture whose uncropped
    /// image starts at `origin` (in points) and has `scale` pixels per point.
    public func regionInPoints(scale: Double, origin: CGPoint = .zero) -> Frame? {
        guard let region else { return nil }
        guard regionUnits == .pixels, scale > 0 else { return region }
        return Frame(
            x: origin.x + region.x / scale, y: origin.y + region.y / scale,
            width: region.width / scale, height: region.height / scale)
    }
}
