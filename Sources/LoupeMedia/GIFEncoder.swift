import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum GIFEncoder {
    /// Encodes frames with a per-frame delay.
    /// - Parameter loop: repeat forever when true, play once when false.
    public static func encode(_ frames: [HeldFrame], loop: Bool = true) throws -> Data {
        guard !frames.isEmpty else { throw MediaError.noFrames }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.gif.identifier as CFString, frames.count, nil)
        else { throw MediaError.encodeFailed("could not create a GIF encoder") }

        // No loop-count block at all is how a GIF says "play once".
        if loop {
            let file = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
            CGImageDestinationSetProperties(destination, file as CFDictionary)
        }
        for frame in frames {
            // Both keys: ImageIO writes the clamped one, and some readers look
            // for the unclamped one.
            let properties = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: frame.delay,
                    kCGImagePropertyGIFUnclampedDelayTime: frame.delay,
                ]
            ]
            CGImageDestinationAddImage(destination, frame.image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw MediaError.encodeFailed("ImageIO could not finalize the GIF")
        }
        return data as Data
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
