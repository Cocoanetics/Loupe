import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Result of comparing two captures.
public struct DiffReport: Codable, Sendable {
    /// Fraction of compared pixels that changed beyond the tolerance, 0…1.
    public var changedFraction: Double
    /// Largest per-channel difference seen anywhere, 0…255.
    public var maxChannelDelta: Int
    /// Bounding boxes of changed regions, in *points*, largest first.
    public var regions: [Frame]
    /// True when the two captures had different pixel dimensions.
    public var sizeChanged: Bool
    public var beforeSize: [Double]
    public var afterSize: [Double]

    public var changedPercent: Double { changedFraction * 100 }

    /// Whether anything meaningful changed. A handful of stray pixels from font
    /// dithering is not a change; see `ImageOps.defaultTolerance`.
    public var isDifferent: Bool { sizeChanged || changedFraction > 0.0001 }

    public var summary: String {
        if sizeChanged {
            return String(
                format: "size changed %.0f×%.0f → %.0f×%.0f, %.2f%% of pixels differ",
                beforeSize.first ?? 0, beforeSize.last ?? 0,
                afterSize.first ?? 0, afterSize.last ?? 0, changedPercent)
        }
        if !isDifferent { return "identical (within tolerance)" }
        return String(
            format: "%.2f%% of pixels differ, max channel delta %d, %d region(s)",
            changedPercent, maxChannelDelta, regions.count)
    }
}

public enum ImageOps {
    /// Per-channel delta below which pixels count as equal.
    ///
    /// Measured rationale: an identical page rendered through two different view
    /// attachment modes differs on ~73% of pixels with a max delta of 3/255 —
    /// gradient dithering, invisible to the eye but fatal to byte equality. A
    /// tolerance of 4 erases that class of noise while still catching a one-shade
    /// color change.
    public static let defaultTolerance = 4

    // MARK: - Codec

    public static func decode(_ png: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw LoupeError.failed("could not decode image data") }
        return image
    }

    public static func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard
            let dest = CGImageDestinationCreateWithData(
                data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw LoupeError.failed("could not create PNG encoder") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw LoupeError.failed("could not encode PNG")
        }
        return data as Data
    }

    /// RGBA8 pixels together with the dimensions they were laid out at.
    ///
    /// A named type rather than a tuple because the diff loop needs all three at
    /// once — a row offset is `y * width * 4` — and the arithmetic only stays
    /// readable while the parts have names.
    struct NormalizedImage {
        var pixels: [UInt8]
        var width: Int
        var height: Int
    }

    /// Redraw into a known RGBA8 layout so two images from different sources are
    /// byte-comparable.
    static func normalize(_ image: CGImage) throws -> NormalizedImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw LoupeError.failed("empty image") }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let ctx = pixels.withUnsafeMutableBytes({ raw -> CGContext? in
                CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            })
        else { throw LoupeError.failed("could not create bitmap context") }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return NormalizedImage(pixels: pixels, width: width, height: height)
    }

    // MARK: - Diff

    public static func diff(
        before: Data,
        after: Data,
        tolerance: Int = defaultTolerance,
        scale: Double = 1.0
    ) throws -> DiffReport {
        let beforeImage = try normalize(try decode(before))
        let afterImage = try normalize(try decode(after))

        let width = min(beforeImage.width, afterImage.width)
        let height = min(beforeImage.height, afterImage.height)
        let sizeChanged =
            beforeImage.width != afterImage.width || beforeImage.height != afterImage.height

        var changed = 0
        var maxDelta = 0
        // Coarse grid of changed cells, later merged into boxes. 16px cells keep
        // this cheap on 5K captures while still localizing a button-sized change.
        let cell = 16
        let cols = (width + cell - 1) / cell
        let rows = (height + cell - 1) / cell
        var grid = [Bool](repeating: false, count: max(cols * rows, 1))

        for y in 0..<height {
            let rowA = y * beforeImage.width * 4
            let rowB = y * afterImage.width * 4
            for x in 0..<width {
                let beforeIndex = rowA + x * 4
                let afterIndex = rowB + x * 4
                var delta = 0
                // RGB only; index 3 is alpha.
                for channel in 0..<3 {
                    let channelDelta =
                        Int(beforeImage.pixels[beforeIndex + channel])
                        - Int(afterImage.pixels[afterIndex + channel])
                    delta = max(delta, abs(channelDelta))
                }
                if delta > maxDelta { maxDelta = delta }
                if delta > tolerance {
                    changed += 1
                    grid[(y / cell) * cols + (x / cell)] = true
                }
            }
        }

        let compared = max(width * height, 1)
        let regions = mergeRegions(grid: grid, cols: cols, rows: rows, cell: cell, scale: scale)

        return DiffReport(
            changedFraction: Double(changed) / Double(compared),
            maxChannelDelta: maxDelta,
            regions: regions,
            sizeChanged: sizeChanged,
            beforeSize: [Double(beforeImage.width), Double(beforeImage.height)],
            afterSize: [Double(afterImage.width), Double(afterImage.height)])
    }

    /// Flood-fill adjacent changed cells into rectangles, biggest first.
    private static func mergeRegions(
        grid: [Bool], cols: Int, rows: Int, cell: Int, scale: Double
    ) -> [Frame] {
        guard cols > 0, rows > 0 else { return [] }
        var seen = [Bool](repeating: false, count: grid.count)
        var out: [Frame] = []

        for row in 0..<rows {
            for column in 0..<cols {
                let idx = row * cols + column
                guard grid[idx], !seen[idx] else { continue }
                var stack = [(column, row)]
                seen[idx] = true
                var minC = column, maxC = column, minR = row, maxR = row
                while let (cellColumn, cellRow) = stack.popLast() {
                    minC = min(minC, cellColumn); maxC = max(maxC, cellColumn)
                    minR = min(minR, cellRow); maxR = max(maxR, cellRow)
                    for (columnStep, rowStep) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nextColumn = cellColumn + columnStep
                        let nextRow = cellRow + rowStep
                        guard nextColumn >= 0, nextColumn < cols, nextRow >= 0, nextRow < rows
                        else { continue }
                        let nextIdx = nextRow * cols + nextColumn
                        guard grid[nextIdx], !seen[nextIdx] else { continue }
                        seen[nextIdx] = true
                        stack.append((nextColumn, nextRow))
                    }
                }
                // Guard against a zero scale turning every box into infinities.
                let safeScale = max(scale, 0.0001)
                out.append(
                    Frame(
                        x: Double(minC * cell) / safeScale,
                        y: Double(minR * cell) / safeScale,
                        width: Double((maxC - minC + 1) * cell) / safeScale,
                        height: Double((maxR - minR + 1) * cell) / safeScale))
            }
        }
        out.sort { $0.width * $0.height > $1.width * $1.height }
        return Array(out.prefix(12))
    }

    // MARK: - Scaling

    /// Downscale so the longest edge is at most `maxEdge` pixels. Used before
    /// handing images to a model: a full 5K capture is ~2,500 image tokens.
    public static func fit(_ png: Data, maxEdge: Int) throws -> Data {
        let image = try decode(png)
        let longest = max(image.width, image.height)
        guard longest > maxEdge else { return png }
        let factor = Double(maxEdge) / Double(longest)
        let targetWidth = max(Int(Double(image.width) * factor), 1)
        let targetHeight = max(Int(Double(image.height) * factor), 1)
        guard
            let ctx = CGContext(
                data: nil, width: targetWidth, height: targetHeight, bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw LoupeError.failed("could not create resize context") }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let out = ctx.makeImage() else { throw LoupeError.failed("could not resize") }
        return try encode(out)
    }
}
