import AVFoundation
import CoreGraphics
import Foundation

public struct GIFOptions: Sendable {
    /// Frames sampled per second of video. Collapsing then drops the still ones.
    public var fps: Double
    /// Output width in pixels; frames are never scaled up.
    public var maxWidth: Int
    /// See ``FrameCollapser/collapse(_:endTime:threshold:)``.
    public var threshold: Double
    public var loop: Bool

    public init(fps: Double = 10, maxWidth: Int = 800, threshold: Double = 0.002, loop: Bool = true) {
        self.fps = fps
        self.maxWidth = maxWidth
        self.threshold = threshold
        self.loop = loop
    }
}

public struct GIFResult: Sendable {
    public var data: Data
    /// Frames sampled from the video.
    public var sampledFrames: Int
    /// Frames in the GIF after still ones were folded together.
    public var keptFrames: Int
    public var duration: TimeInterval
}

public enum VideoConverter {
    /// Hard bound on how many frames one conversion reads.
    static let maxSamples = 3000

    public static func gif(from url: URL, options: GIFOptions = GIFOptions()) async throws -> GIFResult {
        guard options.fps > 0, options.fps <= 60 else {
            throw MediaError.unreadable("--fps must be between 0 and 60")
        }
        guard options.maxWidth > 0 else { throw MediaError.unreadable("--max-width must be positive") }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MediaError.unreadable("no such file: \(url.path)")
        }

        let asset = AVURLAsset(url: url)
        let duration: TimeInterval
        do {
            guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
                throw MediaError.unreadable("\(url.lastPathComponent) has no video track")
            }
            duration = try await asset.load(.duration).seconds
        } catch let error as MediaError {
            throw error
        } catch {
            throw MediaError.unreadable(
                "could not read \(url.lastPathComponent) as video: \(error.localizedDescription)")
        }
        guard duration.isFinite, duration > 0 else { throw MediaError.noFrames }

        let count = min(max(1, Int((duration * options.fps).rounded(.up))), maxSamples)
        let step = duration / Double(count)
        let times = (0..<count).map { CMTime(seconds: Double($0) * step, preferredTimescale: 600) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: options.maxWidth, height: 0)
        // Half a sample of slack: exact seeks cost a decode from the previous
        // keyframe each, and a screen recording is mostly keyframes' worth of sameness.
        let slack = CMTime(seconds: step / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = slack
        generator.requestedTimeToleranceAfter = slack

        var frames: [TimedFrame] = []
        for await result in generator.images(for: times) {
            // A frame that fails to decode is skipped; the previous one is held.
            if case .success(let requested, let image, _) = result {
                frames.append(TimedFrame(image: image, time: requested.seconds))
            }
        }
        frames.sort { $0.time < $1.time }
        guard !frames.isEmpty else { throw MediaError.noFrames }

        let held = FrameCollapser.collapse(frames, endTime: duration, threshold: options.threshold)
        let data = try GIFEncoder.encode(held, loop: options.loop)
        return GIFResult(
            data: data, sampledFrames: frames.count, keptFrames: held.count, duration: duration)
    }
}
