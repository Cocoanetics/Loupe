import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum GIFEncoder {
    /// Encodes frames with a per-frame delay.
    /// - Parameter loop: repeat forever when true, play once when false.
    public static func encode(_ frames: [HeldFrame], loop: Bool = true) throws -> Data {
        guard !frames.isEmpty else { throw MediaError.noFrames }
        let stream = try Stream(frameCount: frames.count, loop: loop)
        for frame in frames { stream.add(frame) }
        return try stream.finalize()
    }

    /// Adds frames one at a time, for a caller that learns each frame's delay
    /// only when the next one arrives and does not want to keep them all.
    public final class Stream {
        private let data = NSMutableData()
        private let destination: CGImageDestination
        private(set) var frameCount = 0

        /// - Parameter frameCount: how many frames will be added.
        public init(frameCount: Int, loop: Bool) throws {
            guard
                let destination = CGImageDestinationCreateWithData(
                    data, UTType.gif.identifier as CFString, max(frameCount, 1), nil)
            else { throw MediaError.encodeFailed("could not create a GIF encoder") }
            self.destination = destination
            // No loop-count block at all is how a GIF says "play once".
            if loop {
                let file = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
                CGImageDestinationSetProperties(destination, file as CFDictionary)
            }
        }

        public func add(_ frame: HeldFrame) {
            // Both keys: ImageIO writes the clamped one, and some readers look
            // for the unclamped one.
            let properties = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: frame.delay,
                    kCGImagePropertyGIFUnclampedDelayTime: frame.delay
                ]
            ]
            CGImageDestinationAddImage(destination, frame.image, properties as CFDictionary)
            frameCount += 1
        }

        public func finalize() throws -> Data {
            guard frameCount > 0 else { throw MediaError.noFrames }
            guard CGImageDestinationFinalize(destination) else {
                throw MediaError.encodeFailed("ImageIO could not finalize the GIF")
            }
            return data as Data
        }
    }
}

public enum MediaError: LocalizedError {
    case noFrames
    case unreadable(String)
    case encodeFailed(String)

    public var errorDescription: String? {
        switch self {
            case .noFrames: return "the video has no frames to convert"
            case .unreadable(let what): return what
            case .encodeFailed(let what): return what
        }
    }
}
