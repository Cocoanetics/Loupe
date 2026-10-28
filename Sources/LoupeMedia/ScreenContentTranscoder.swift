import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import LoupeCore
import VideoToolbox

public struct TranscodeResult: Sendable {
    /// Frames in the source.
    public var sourceFrames: Int
    /// Samples written: only frames where the screen changed.
    public var writtenFrames: Int
}

/// A part of the screen to keep: points, origin top-left (see ``RecordCrop``).
public struct ScreenCrop: Sendable {
    public var region: Frame
    public var scale: Double

    public init(region: Frame, scale: Double) {
        self.region = region
        self.scale = scale
    }
}

/// Re-encodes a screen recording for what a screen actually is: long stretches of
/// nothing, punctuated by sharp text.
///
/// - H.264 High profile, because X and every browser play it. HEVC and AV1 have
///   screen-content tools but no VideoToolbox encoder and no broad playback.
/// - Variable frame rate: a sample is written only when the frame changed, using
///   the same detector as the GIF path, and the last one is held to the end.
/// - Native resolution, optionally cropped to a region; UI text does not survive downscaling.
/// - High quality (0.85) rather than a bitrate, so text edges stay clean.
public enum ScreenContentTranscoder {
    /// Stricter than the GIF default: a video keeps subtle changes, a GIF is
    /// allowed to lose them for size.
    public static let defaultThreshold = 0.0005

    public static let quality = 0.85

    public static func transcode(
        from source: URL, to destination: URL, crop: ScreenCrop? = nil,
        threshold: Double = defaultThreshold
    ) async throws -> TranscodeResult {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.unreadable("\(source.lastPathComponent) has no video track")
        }
        let duration = try await asset.load(.duration)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let sourceWidth = Int(size.width.rounded())
        let sourceHeight = Int(size.height.rounded())
        guard sourceWidth > 0, sourceHeight > 0 else { throw MediaError.noFrames }
        let rect: CGRect
        if let crop {
            rect = try RecordCrop.pixelRect(
                crop.region, scale: crop.scale, pixelWidth: sourceWidth, pixelHeight: sourceHeight)
        } else {
            rect = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        }
        let width = Int(rect.width)
        let height = Int(rect.height)

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
            guard let full = CMSampleBufferGetImageBuffer(sample) else { continue }
            sourceFrames += 1
            let pixels = crop == nil ? full : try cropped(full, to: rect, pool: adaptor.pixelBufferPool)
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

extension ScreenContentTranscoder {
    /// Copies `rect` out of a 32-bit BGRA buffer, row by row.
    static func cropped(_ source: CVPixelBuffer, to rect: CGRect, pool: CVPixelBufferPool?) throws
        -> CVPixelBuffer {
        let width = Int(rect.width)
        let height = Int(rect.height)
        var made: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        } else {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &made)
        }
        guard let target = made else { throw MediaError.encodeFailed("could not allocate a frame") }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(target, [])
        defer {
            CVPixelBufferUnlockBaseAddress(target, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let from = CVPixelBufferGetBaseAddress(source),
            let to = CVPixelBufferGetBaseAddress(target)
        else { throw MediaError.encodeFailed("could not map a frame") }
        let fromStride = CVPixelBufferGetBytesPerRow(source)
        let toStride = CVPixelBufferGetBytesPerRow(target)
        let originX = Int(rect.minX)
        let originY = Int(rect.minY)
        for row in 0..<height {
            memcpy(
                to + row * toStride, from + (originY + row) * fromStride + originX * 4, width * 4)
        }
        return target
    }
}
