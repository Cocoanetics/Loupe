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

/// Decides, frame by frame, whether the screen changed. Shared by the GIF path and
/// the MP4 transcode, so both mean the same by "unchanged".
///
/// Compares against the last *kept* frame, not the previous one: a slow fade
/// changes every step by less than the threshold and would otherwise be
/// discarded in full.
struct FrameChangeDetector {
    var threshold: Double
    private var last: [UInt8]?

    init(threshold: Double) { self.threshold = threshold }

    /// True for the first frame and for any frame that differs enough from the
    /// last one that returned true.
    mutating func isChange(_ image: CGImage) -> Bool {
        let signature = FrameCollapser.signature(of: image)
        if let last, FrameCollapser.difference(last, signature) < threshold { return false }
        last = signature
        return true
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
    ) throws -> [HeldFrame] {
        let collected = Collected()
        var stream = Stream(threshold: threshold) { collected.frames.append($0) }
        for frame in frames { try stream.add(frame) }
        try stream.finish(endTime: endTime)
        return collected.frames
    }

    private final class Collected: @unchecked Sendable {
        var frames: [HeldFrame] = []
    }

    /// Collapses frames as they arrive, so a caller decoding a long clip never
    /// holds more than one frame: the last kept one, waiting for the next change
    /// to say how long it stays on screen. Each frame is handed to `sink` the
    /// moment its hold is known.
    public struct Stream {
        private var detector: FrameChangeDetector
        private var pending: TimedFrame?
        private let sink: (HeldFrame) throws -> Void

        public init(threshold: Double, sink: @escaping (HeldFrame) throws -> Void) {
            detector = FrameChangeDetector(threshold: threshold)
            self.sink = sink
        }

        /// Frames held in memory by this stream: 0 before the first, then 1.
        public var retainedFrames: Int { pending == nil ? 0 : 1 }

        public mutating func add(_ frame: TimedFrame) throws {
            guard detector.isChange(frame.image) else { return }
            try flush(until: frame.time)
            pending = frame
        }

        public mutating func finish(endTime: TimeInterval) throws {
            try flush(until: endTime)
            pending = nil
        }

        private func flush(until time: TimeInterval) throws {
            guard let pending else { return }
            let delay = min(max(time - pending.time, FrameCollapser.minDelay), FrameCollapser.maxDelay)
            try sink(HeldFrame(image: pending.image, delay: delay))
        }
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
    static func difference(_ first: [UInt8], _ second: [UInt8]) -> Double {
        guard first.count == second.count, !first.isEmpty else { return 1 }
        var total = 0
        for index in first.indices { total += abs(Int(first[index]) - Int(second[index])) }
        return Double(total) / Double(first.count * 255)
    }
}
