import CoreGraphics
import CoreText
import Foundation

extension ImageOps {
    /// Build the side-by-side proof image: BEFORE | AFTER, changed regions boxed
    /// in the after panel, and a caption strip underneath.
    public static func sideBySide(
        before: Data,
        after: Data,
        report: DiffReport?,
        beforeLabel: String = "BEFORE",
        afterLabel: String = "AFTER",
        caption: String? = nil,
        scale: Double = 1.0
    ) throws -> Data {
        let beforeImage = try decode(before)
        let afterImage = try decode(after)

        let gutter = 24
        let header = 56
        let captionHeight = caption == nil ? 0 : 52
        let panelWidth = max(beforeImage.width, afterImage.width)
        let panelHeight = max(beforeImage.height, afterImage.height)
        let width = panelWidth * 2 + gutter * 3
        let height = panelHeight + header + gutter * 2 + captionHeight

        guard
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw LoupeError.failed("could not create composition context") }

        // CoreGraphics is bottom-left origin; flip so the layout math below reads
        // top-down like the eventual image.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        ctx.setFillColor(CGColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let leftX = gutter
        let rightX = gutter * 2 + panelWidth
        let panelY = header

        drawPanel(ctx, beforeImage, x: leftX, y: panelY, canvasHeight: height)
        drawPanel(ctx, afterImage, x: rightX, y: panelY, canvasHeight: height)

        drawLabel(ctx, beforeLabel, at: CGPoint(x: leftX, y: 16), size: 26)
        drawLabel(ctx, afterLabel, at: CGPoint(x: rightX, y: 16), size: 26)

        if let report {
            strokeChangedRegions(
                ctx, report, panelOrigin: CGPoint(x: rightX, y: panelY), scale: scale)
        }

        if let caption {
            drawLabel(
                ctx, caption,
                at: CGPoint(x: gutter, y: header + panelHeight + gutter),
                size: 22, alpha: 0.75)
        }

        guard let image = ctx.makeImage() else {
            throw LoupeError.failed("could not render composition")
        }
        return try encode(image)
    }

    /// Draw one capture into its panel, hairline-framed.
    ///
    /// `canvasHeight` is needed because the caller has already flipped the context
    /// to a top-down space: the bitmap has to be drawn in the unflipped space or it
    /// comes out mirrored.
    private static func drawPanel(
        _ ctx: CGContext, _ image: CGImage, x: Int, y: Int, canvasHeight: Int
    ) {
        let rect = CGRect(x: x, y: y, width: image.width, height: image.height)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(canvasHeight))
        ctx.scaleBy(x: 1, y: -1)
        // Undo the outer flip for the bitmap itself, else it draws mirrored.
        let flipped = CGRect(
            x: rect.minX, y: CGFloat(canvasHeight) - rect.maxY,
            width: rect.width, height: rect.height)
        ctx.draw(image, in: flipped)
        ctx.restoreGState()
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.18))
        ctx.setLineWidth(1)
        ctx.stroke(rect)
    }

    /// Box the changed regions on the after panel.
    ///
    /// Regions are measured over the overlap of the two captures, so they are left
    /// off entirely when the sizes differ.
    private static func strokeChangedRegions(
        _ ctx: CGContext, _ report: DiffReport, panelOrigin: CGPoint, scale: Double
    ) {
        guard !report.sizeChanged else { return }
        ctx.setStrokeColor(CGColor(red: 1.0, green: 0.29, blue: 0.36, alpha: 0.95))
        ctx.setLineWidth(3)
        for region in report.regions {
            let box = CGRect(
                x: panelOrigin.x + region.x * scale,
                y: panelOrigin.y + region.y * scale,
                width: region.width * scale,
                height: region.height * scale)
            ctx.stroke(box.insetBy(dx: -2, dy: -2))
        }
    }

    private static func drawLabel(
        _ ctx: CGContext, _ text: String, at point: CGPoint, size: CGFloat, alpha: CGFloat = 1
    ) {
        let font = CTFontCreateWithName("SFMono-Semibold" as CFString, size, nil)
        // CoreText attribute keys, not AppKit's — LoupeCore stays UI-framework free.
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: alpha)
        ]
        let attributed = CFAttributedStringCreate(
            nil, text as CFString, attributes as CFDictionary)
        guard let attributed else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.saveGState()
        ctx.textMatrix = .identity
        // Undo the outer top-down flip for glyphs, which would otherwise render
        // upside down.
        ctx.translateBy(x: point.x, y: point.y + size)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
