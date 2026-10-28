import CoreGraphics
import Foundation

/// A frame and the moment it was shown, in seconds from the start of the clip.
public struct TimedFrame: @unchecked Sendable {
    public var image: CGImage
    public var time: TimeInterval

    public init(image: CGImage, time: TimeInterval) {
        self.image = image
        self.time = time
    }
}

/// A frame and how long it stays on screen.
public struct HeldFrame: @unchecked Sendable {
    public var image: CGImage
    public var delay: TimeInterval

    public init(image: CGImage, delay: TimeInterval) {
        self.image = image
        self.delay = delay
    }
}

/// Folds runs of unchanged frames into one frame held for the combined time, so
/// a ten second clip with half a second of motion becomes a handful of frames.
public enum FrameCollapser {
    /// Browsers treat delays under 20 ms as "unspecified" and play them at
    /// ~100 ms, so a shorter hold would make the change look slower, not faster.
    public static let minDelay: TimeInterval = 0.02

    /// A GIF delay is a 16-bit count of centiseconds.
    public static let maxDelay: TimeInterval = 655

    /// - Parameters:
    ///   - frames: in time order.
    ///   - endTime: when the clip ends, so the last frame gets its hold.
    ///   - threshold: mean absolute luminance difference, 0...1, below which a
    ///     frame counts as unchanged.
    public static func collapse(
        _ frames: [TimedFrame], endTime: TimeInterval, threshold: Double
    ) -> [HeldFrame] {
        var kept: [(image: CGImage, start: TimeInterval, signature: [UInt8])] = []
        for frame in frames {
            let signature = Self.signature(of: frame.image)
            // Against the last *kept* frame, not the previous one: a slow fade
            // changes every step by less than the threshold and would otherwise
            // be discarded in full.
            if let last = kept.last, difference(last.signature, signature) < threshold {
                continue
            }
            kept.append((frame.image, frame.time, signature))
        }
        var held: [HeldFrame] = []
        for (index, frame) in kept.enumerated() {
            let next = index + 1 < kept.count ? kept[index + 1].start : endTime
            let delay = min(max(next - frame.start, minDelay), maxDelay)
            held.append(HeldFrame(image: frame.image, delay: delay))
        }
        return held
    }

    /// Width of the grayscale thumbnail frames are compared on.
    private static let thumbnailWidth = 192

    static func signature(of image: CGImage) -> [UInt8] {
        let width = thumbnailWidth
        let height = max(1, Int((Double(image.height) / Double(max(image.width, 1)) * Double(width)).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    /// Mean absolute difference, 0...1. Thumbnails of different size count as
    /// entirely different.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var total = 0
        for index in a.indices { total += abs(Int(a[index]) - Int(b[index])) }
        return Double(total) / Double(a.count * 255)
    }
}
