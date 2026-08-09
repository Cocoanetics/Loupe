import CoreGraphics
import CoreText
import Foundation

/// One element marked on an annotated capture.
public struct Annotation: Codable, Sendable {
    /// The number drawn on the image.
    public var number: Int
    /// Handle to pass back to `press`/`setValue`.
    public var id: String
    public var role: String
    public var label: String?
    /// Where it is, in the same space as the capture's points.
    public var frame: Frame

    public init(number: Int, id: String, role: String, label: String?, frame: Frame) {
        self.number = number
        self.id = id
        self.role = role
        self.label = label
        self.frame = frame
    }

    public var caption: String {
        let text = label.map { $0.count > 34 ? String($0.prefix(33)) + "…" : $0 } ?? ""
        return "\(number). \(role)\(text.isEmpty ? "" : " \"\(text)\"")"
    }
}

extension ImageOps {

    /// Draw numbered boxes around elements on a capture.
    ///
    /// This is the bridge between looking and acting. A model reading a raw
    /// screenshot has to guess coordinates, and a coordinate guessed from a
    /// downscaled image is often a few points off — enough to hit the wrong
    /// control. Numbering the elements removes the guess entirely: the model reads
    /// "3", and `press:3`'s handle came from the accessibility tree, so the action
    /// is exact even though the perception was approximate.
    public static func annotate(
        _ png: Data,
        annotations: [Annotation],
        scale: Double,
        origin: Frame? = nil
    ) throws -> Data {
        let image = try decode(png)
        let legendHeight = annotations.isEmpty ? 0 : min(annotations.count, 24) * 26 + 24
        let width = image.width
        let height = image.height + legendHeight

        guard
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw LoupeError.failed("could not create annotation context") }

        ctx.setFillColor(CGColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: CGRect(x: 0, y: legendHeight, width: image.width, height: image.height))

        // Top-down coordinates from here, matching how frames are reported.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        for annotation in annotations {
            let frame = annotation.frame
            let rect = CGRect(
                x: (frame.x - (origin?.x ?? 0)) * scale,
                y: (frame.y - (origin?.y ?? 0)) * scale,
                width: frame.width * scale,
                height: frame.height * scale)
            guard rect.width > 1, rect.height > 1 else { continue }

            ctx.setStrokeColor(CGColor(red: 1.0, green: 0.29, blue: 0.36, alpha: 0.95))
            ctx.setLineWidth(2)
            ctx.stroke(rect)

            // Badge in the corner, clamped inside the image so a control at the very
            // edge still gets a readable number.
            let badge = CGRect(
                x: min(max(rect.minX, 0), CGFloat(width) - 34),
                y: min(max(rect.minY, 0), CGFloat(image.height) - 24),
                width: 34, height: 24)
            ctx.setFillColor(CGColor(red: 1.0, green: 0.29, blue: 0.36, alpha: 0.95))
            ctx.fill(badge)
            drawText(
                ctx, "\(annotation.number)", at: CGPoint(x: badge.minX + 8, y: badge.minY + 2), size: 17)
        }

        // Legend under the image, so the numbers mean something without a second call.
        var y = CGFloat(image.height) + 12
        for annotation in annotations.prefix(24) {
            drawText(ctx, annotation.caption, at: CGPoint(x: 14, y: y), size: 17, alpha: 0.85)
            y += 26
        }
        if annotations.count > 24 {
            drawText(
                ctx, "… and \(annotations.count - 24) more; narrow with --filter",
                at: CGPoint(x: 14, y: y - 26), size: 15, alpha: 0.6)
        }

        guard let out = ctx.makeImage() else {
            throw LoupeError.failed("could not render annotations")
        }
        return try encode(out)
    }

    private static func drawText(
        _ ctx: CGContext, _ text: String, at point: CGPoint, size: CGFloat, alpha: CGFloat = 1
    ) {
        let font = CTFontCreateWithName("SFMono-Semibold" as CFString, size, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: alpha)
        ]
        guard
            let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: point.x, y: point.y + size)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
