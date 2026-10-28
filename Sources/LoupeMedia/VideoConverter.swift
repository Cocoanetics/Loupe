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
    /// Most frames held in memory at once while converting.
    public var peakRetainedFrames: Int
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

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: options.maxWidth, height: 0)
        // Half a sample of slack: exact seeks cost a decode from the previous
        // keyframe each, and a screen recording is mostly keyframes' worth of sameness.
        let slack = CMTime(seconds: step / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = slack
        generator.requestedTimeToleranceAfter = slack

        return try await encode(sampleCount: count, duration: duration, options: options) { index in
            let time = CMTime(seconds: Double(index) * step, preferredTimescale: 600)
            // A frame that fails to decode is skipped; the previous one is held.
            guard let image = try? await generator.image(at: time).image else { return nil }
            return TimedFrame(image: image, time: time.seconds)
        }
    }

    /// Pulls `sampleCount` frames one by one from `frame` and collapses them as
    /// they arrive, so memory holds one frame, not the clip. A nil frame is a
    /// sample that could not be read.
    static func encode(
        sampleCount: Int, duration: TimeInterval, options: GIFOptions,
        frame: (Int) async throws -> TimedFrame?
    ) async throws -> GIFResult {
        // The count is only known after collapsing, but the encoder wants it up
        // front; the sample count is the most it can be.
        let encoder = try GIFEncoder.Stream(frameCount: sampleCount, loop: options.loop)
        var stream = FrameCollapser.Stream(threshold: options.threshold) { encoder.add($0) }
        var sampled = 0
        var peak = 0
        for index in 0..<sampleCount {
            guard let next = try await frame(index) else { continue }
            sampled += 1
            try stream.add(next)
            peak = max(peak, stream.retainedFrames)
        }
        guard sampled > 0 else { throw MediaError.noFrames }
        try stream.finish(endTime: duration)
        let data = try encoder.finalize()
        return GIFResult(
            data: data, sampledFrames: sampled, keptFrames: encoder.frameCount, duration: duration,
            peakRetainedFrames: peak)
    }
}
