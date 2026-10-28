import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import VideoToolbox

public struct TranscodeResult: Sendable {
    /// Frames in the source.
    public var sourceFrames: Int
    /// Samples written: only frames where the screen changed.
    public var writtenFrames: Int
}

/// Re-encodes a screen recording for what a screen actually is: long stretches of
/// nothing, punctuated by sharp text.
///
/// - H.264 High profile, because X and every browser play it. HEVC and AV1 have
///   screen-content tools but no VideoToolbox encoder and no broad playback.
/// - Variable frame rate: a sample is written only when the frame changed, using
///   the same detector as the GIF path, and the last one is held to the end.
/// - Native resolution; UI text does not survive downscaling.
/// - High quality (0.85) rather than a bitrate, so text edges stay clean.
public enum ScreenContentTranscoder {
    /// Stricter than the GIF default: a video keeps subtle changes, a GIF is
    /// allowed to lose them for size.
    public static let defaultThreshold = 0.0005

    public static let quality = 0.85

    public static func transcode(
        from source: URL, to destination: URL, threshold: Double = defaultThreshold
    ) async throws -> TranscodeResult {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.unreadable("\(source.lastPathComponent) has no video track")
        }
        let duration = try await asset.load(.duration)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { throw MediaError.noFrames }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        // A frame is held after the loop moves on, so it must be ours, not recycled.
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else { throw MediaError.unreadable("cannot read the video track") }
        reader.add(output)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoQualityKey: quality,
                    // No B-frames: the pictures are sparse, and reordering would
                    // only complicate the presentation times of a VFR stream.
                    AVVideoAllowFrameReorderingKey: false,
                ],
            ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { throw MediaError.encodeFailed("cannot write H.264") }
        writer.add(input)

        guard reader.startReading() else {
            throw MediaError.unreadable(reader.error?.localizedDescription ?? "cannot read the video")
        }
        guard writer.startWriting() else {
            throw MediaError.encodeFailed(writer.error?.localizedDescription ?? "cannot start writing")
        }
        writer.startSession(atSourceTime: .zero)

        var detector = FrameChangeDetector(threshold: threshold)
        var sourceFrames = 0
        var written = 0
        var lastKept: (pixels: CVPixelBuffer, time: CMTime)?
        while let sample = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            sourceFrames += 1
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
            // A frame that cannot be inspected is kept, not guessed at.
            if let image, !detector.isChange(image) { continue }
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let time = max(CMSampleBufferGetPresentationTimeStamp(sample), .zero)
            guard adaptor.append(pixels, withPresentationTime: time) else { break }
            written += 1
            lastKept = (pixels, time)
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw MediaError.unreadable(reader.error?.localizedDescription ?? "reading failed")
        }
        // The container's duration comes from the last sample, so a screen that
        // stayed still would otherwise play as a single frame. Repeat the last
        // picture just before the end; it costs a few bytes and fixes the length
        // for every player, not only the ones that honour the session end.
        let tail = CMTimeSubtract(duration, CMTime(value: 1, timescale: 30))
        if let lastKept, CMTimeCompare(tail, lastKept.time) > 0 {
            while !input.isReadyForMoreMediaData, writer.status != .failed {
                try await Task.sleep(for: .milliseconds(5))
            }
            if adaptor.append(lastKept.pixels, withPresentationTime: tail) { written += 1 }
        }
        input.markAsFinished()
        // Ends the session at the source's end, which is what holds the last
        // sample for as long as the screen really stayed that way.
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        guard writer.status == .completed, written > 0 else {
            throw MediaError.encodeFailed(
                writer.error?.localizedDescription ?? "the encoder wrote no frames")
        }
        return TranscodeResult(sourceFrames: sourceFrames, writtenFrames: written)
    }
}
