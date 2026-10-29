import Accelerate
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
    /// Size of the encoded picture, after any crop and any scaling.
    public var width: Int
    public var height: Int
    /// What the encoder had to give up, for a human: scaling, a bitrate fallback.
    public var notes: [String]
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
///   A `--max-size` box (``MaxSize``) is the one deliberate exception. Otherwise only
///   a picture past what H.264 can take (4096 on the long edge, 4096×2304 in
///   area, level 5.2) is scaled down to fit, and the result says so: a 5K desktop
///   would otherwise have no encoder at all.
/// - High quality (0.85) rather than a bitrate, so text edges stay clean. Where the
///   encoder takes no quality setting, an average bitrate sized to the picture.
public enum ScreenContentTranscoder {
    /// Stricter than the GIF default: a video keeps subtle changes, a GIF is
    /// allowed to lose them for size.
    public static let defaultThreshold = 0.0005

    public static let quality = 0.85

    /// Reader and writer, wired up and started.
    private struct Pipeline {
        var reader: AVAssetReader
        var output: AVAssetReaderTrackOutput
        var writer: AVAssetWriter
        var input: AVAssetWriterInput
        var adaptor: AVAssetWriterInputPixelBufferAdaptor
        var rect: CGRect
        var duration: CMTime
        /// The encoded size; frames are scaled to it when it is not `rect`'s.
        var width: Int
        var height: Int
        var notes: [String]

        var isScaled: Bool { (width, height) != (Int(rect.width), Int(rect.height)) }
    }

    /// What the frame loop leaves behind.
    private struct Tally {
        var sourceFrames = 0
        var written = 0
        var lastKept: (pixels: CVPixelBuffer, time: CMTime)?
    }

    public static func transcode(
        from source: URL, to destination: URL, crop: ScreenCrop? = nil,
        maxSize: MaxSize? = nil, threshold: Double = defaultThreshold
    ) async throws -> TranscodeResult {
        let pipeline = try await makePipeline(from: source, to: destination, crop: crop, maxSize: maxSize)
        // Decoding, cropping and scaling block; on a thread of their own, a slow
        // or stuck frame holds up this transcode, not Swift's cooperative pool.
        let carried = Unchecked(pipeline)
        let carriedTally: Unchecked<Tally> = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue(label: "com.cocoanetics.loupe.transcode").async {
                continuation.resume(with: Result {
                    Unchecked(try encodeFrames(carried.value, cropping: crop != nil, threshold: threshold))
                })
            }
        }
        let tally = carriedTally.value
        if pipeline.reader.status == .failed {
            pipeline.writer.cancelWriting()
            throw MediaError.unreadable(pipeline.reader.error?.localizedDescription ?? "reading failed")
        }
        try await finish(pipeline, repeating: tally.lastKept)
        guard pipeline.writer.status == .completed, tally.written > 0 else {
            throw MediaError.encodeFailed(
                pipeline.writer.error?.localizedDescription ?? "the encoder wrote no frames")
        }
        return TranscodeResult(
            sourceFrames: tally.sourceFrames, writtenFrames: tally.written, width: pipeline.width,
            height: pipeline.height, notes: pipeline.notes)
    }

    /// Reads, crops, scales and appends every changed frame. Blocks; call it off the cooperative pool.
    private static func encodeFrames(_ pipeline: Pipeline, cropping: Bool, threshold: Double) throws -> Tally {
        var detector = FrameChangeDetector(threshold: threshold)
        var tally = Tally()
        while let sample = pipeline.output.copyNextSampleBuffer() {
            guard let full = CMSampleBufferGetImageBuffer(sample) else { continue }
            tally.sourceFrames += 1
            let pool = pipeline.adaptor.pixelBufferPool
            // The adaptor's pool holds encoded-size buffers, so a crop that is
            // scaled afterwards needs its own.
            var pixels = cropping
                ? try cropped(full, to: pipeline.rect, pool: pipeline.isScaled ? nil : pool) : full
            if pipeline.isScaled {
                pixels = try scaled(pixels, width: pipeline.width, height: pipeline.height, pool: pool)
            }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
            // A frame that cannot be inspected is kept, not guessed at.
            if let image, !detector.isChange(image) { continue }
            while !pipeline.input.isReadyForMoreMediaData, pipeline.writer.status != .failed {
                Thread.sleep(forTimeInterval: 0.005)
            }
            let time = max(CMSampleBufferGetPresentationTimeStamp(sample), .zero)
            guard pipeline.adaptor.append(pixels, withPresentationTime: time) else { break }
            tally.written += 1
            tally.lastKept = (pixels, time)
        }
        return tally
    }

    private static func waitUntilReady(_ pipeline: Pipeline) async throws {
        while !pipeline.input.isReadyForMoreMediaData, pipeline.writer.status != .failed {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func finish(_ pipeline: Pipeline, repeating last: (pixels: CVPixelBuffer, time: CMTime)?)
        async throws {
        // The container's duration comes from the last sample, so a screen that
        // stayed still would otherwise play as a single frame. Repeat the last
        // picture just before the end; it costs a few bytes and fixes the length
        // for every player, not only the ones that honour the session end.
        let tail = CMTimeSubtract(pipeline.duration, CMTime(value: 1, timescale: 30))
        if let last, CMTimeCompare(tail, last.time) > 0 {
            try await waitUntilReady(pipeline)
            _ = pipeline.adaptor.append(last.pixels, withPresentationTime: tail)
        }
        pipeline.input.markAsFinished()
        // Ends the session at the source's end, which is what holds the last
        // sample for as long as the screen really stayed that way.
        pipeline.writer.endSession(atSourceTime: pipeline.duration)
        await pipeline.writer.finishWriting()
    }

    private static func makePipeline(from source: URL, to destination: URL, crop: ScreenCrop?, maxSize: MaxSize?)
        async throws -> Pipeline {
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
        var rect = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        if let crop {
            rect = try RecordCrop.pixelRect(
                crop.region, scale: crop.scale, pixelWidth: sourceWidth, pixelHeight: sourceHeight)
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        // A frame is held after the loop moves on, so it must be ours, not recycled.
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else { throw MediaError.unreadable("cannot read the video track") }
        reader.add(output)

        var notes: [String] = []
        let (width, height) = plannedSize(rect.size, maxSize: maxSize, transform: transform, notes: &notes)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        // AVAssetWriterInput raises an Objective-C exception, which Swift cannot
        // catch, for settings the encoder refuses; ask first.
        let settings = try applicableSettings(width: width, height: height, writer: writer, notes: &notes)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = scaled(transform, from: rect.size, toWidth: width, height: height)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
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
        return Pipeline(
            reader: reader, output: output, writer: writer, input: input, adaptor: adaptor,
            rect: rect, duration: duration, width: width, height: height, notes: notes)
    }

    /// `transform` for frames scaled from `size` to `width`×`height`. The rotation
    /// stays; the translation that moves a rotated picture back into view refers
    /// to the old size, so it is scaled with the picture as it is displayed.
    static func scaled(_ transform: CGAffineTransform, from size: CGSize, toWidth width: Int, height: Int)
        -> CGAffineTransform {
        guard size != CGSize(width: width, height: height), size.width > 0, size.height > 0 else {
            return transform
        }
        var linear = transform
        linear.tx = 0
        linear.ty = 0
        let before = CGRect(origin: .zero, size: size).applying(linear)
        let after = CGRect(x: 0, y: 0, width: width, height: height).applying(linear)
        // Whatever offset the track had beyond bringing the picture into view, scaled.
        linear.tx = -after.minX + (transform.tx + before.minX) * after.width / before.width
        linear.ty = -after.minY + (transform.ty + before.minY) * after.height / before.height
        return linear
    }

    /// The encoded size: `size` fitted into `maxSize`, then into H.264's limit,
    /// with a note for each step that scaled it.
    private static func plannedSize(
        _ size: CGSize, maxSize: MaxSize?, transform: CGAffineTransform, notes: inout [String]
    ) -> (width: Int, height: Int) {
        let (boxedWidth, boxedHeight) = boxed(size, into: maxSize, transform: transform)
        if (boxedWidth, boxedHeight) != (Int(size.width), Int(size.height)), let maxSize {
            notes.append(
                "h264: scaled \(Int(size.width))×\(Int(size.height)) → \(boxedWidth)×\(boxedHeight) "
                    + "(--max-size \(maxSize))")
        }
        let (width, height) = encodedSize(width: boxedWidth, height: boxedHeight)
        if (width, height) != (boxedWidth, boxedHeight) {
            notes.append("h264: scaled \(boxedWidth)×\(boxedHeight) → \(width)×\(height) (H.264 limit)")
        }
        return (width, height)
    }

    /// `size`, in the track's own pixels, fitted into `maxSize` as the picture is
    /// shown: a preset box turns with a track that `transform` rotates to portrait.
    static func boxed(_ size: CGSize, into maxSize: MaxSize?, transform: CGAffineTransform)
        -> (width: Int, height: Int) {
        guard let maxSize else { return (Int(size.width), Int(size.height)) }
        let quarterTurn = abs(transform.b) > abs(transform.a)
        let shown = quarterTurn ? CGSize(width: size.height, height: size.width) : size
        let fitted = maxSize.fit(shown)
        return quarterTurn
            ? (Int(fitted.height), Int(fitted.width)) : (Int(fitted.width), Int(fitted.height))
    }

    /// The quality-based settings, or an average bitrate where the encoder for
    /// this size takes no quality setting; an error where it takes neither.
    static func applicableSettings(width: Int, height: Int, writer: AVAssetWriter, notes: inout [String])
        throws -> [String: Any] {
        let preferred = videoSettings(width: width, height: height, rate: [AVVideoQualityKey: quality])
        if writer.canApply(outputSettings: preferred, forMediaType: .video) { return preferred }
        let bitsPerSecond = width * height * 4
        let fallback = videoSettings(
            width: width, height: height, rate: [AVVideoAverageBitRateKey: bitsPerSecond])
        guard writer.canApply(outputSettings: fallback, forMediaType: .video) else {
            throw MediaError.encodeFailed("the encoder cannot encode \(width)×\(height) H.264")
        }
        notes.append(
            "h264: no quality setting at \(width)×\(height); used an average bitrate of "
                + "\(bitsPerSecond / 1_000_000) Mbit/s")
        return fallback
    }

    private static func videoSettings(width: Int, height: Int, rate: [String: Any]) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: rate.merging([
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                // No B-frames: the pictures are sparse, and reordering would
                // only complicate the presentation times of a VFR stream.
                AVVideoAllowFrameReorderingKey: false
            ]) { kept, _ in kept }
        ]
    }

    /// H.264's frame-size limits as the encoders apply them: 4096 on the long
    /// edge, and level 5.2's 36 864 macroblocks (4096×2304) in area.
    static let maxEdge = 4096
    static let maxMacroblocks = 36_864

    /// `width`×`height` scaled down, keeping its shape and even sides, until H.264
    /// takes it; unchanged when it already fits.
    static func encodedSize(width: Int, height: Int) -> (width: Int, height: Int) {
        func fits(_ width: Int, _ height: Int) -> Bool {
            max(width, height) <= maxEdge && ((width + 15) / 16) * ((height + 15) / 16) <= maxMacroblocks
        }
        guard width > 0, height > 0, !fits(width, height) else { return (width, height) }
        let area = Double(maxMacroblocks * 256) / (Double(width) * Double(height))
        var factor = min(Double(maxEdge) / Double(max(width, height)), area.squareRoot())
        while true {
            // The epsilon keeps an exact fit, such as 5120 × 0.8, from flooring to one less.
            let scaledWidth = max(2, Int(Double(width) * factor + 1e-6) & ~1)
            let scaledHeight = max(2, Int(Double(height) * factor + 1e-6) & ~1)
            if fits(scaledWidth, scaledHeight) { return (scaledWidth, scaledHeight) }
            factor *= 0.995
        }
    }
}

extension ScreenContentTranscoder {
    /// Scales a 32-bit BGRA `source` to `width`×`height`, into a buffer from the writer's pool.
    ///
    /// On the CPU with vImage rather than `VTPixelTransferSession`: that one wants
    /// a hardware scaler, and where there is none (a virtual Mac) it can block
    /// instead of failing.
    static func scaled(_ source: CVPixelBuffer, width: Int, height: Int, pool: CVPixelBufferPool?) throws
        -> CVPixelBuffer {
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
            let destination = CVPixelBufferGetBaseAddress(target)
        else { throw MediaError.encodeFailed("could not map a frame") }
        var input = vImage_Buffer(
            data: from, height: vImagePixelCount(CVPixelBufferGetHeight(source)),
            width: vImagePixelCount(CVPixelBufferGetWidth(source)), rowBytes: CVPixelBufferGetBytesPerRow(source))
        var output = vImage_Buffer(
            data: destination, height: vImagePixelCount(CVPixelBufferGetHeight(target)),
            width: vImagePixelCount(CVPixelBufferGetWidth(target)), rowBytes: CVPixelBufferGetBytesPerRow(target))
        // Four 8-bit channels; their order does not matter to the scaler.
        guard vImageScale_ARGB8888(&input, &output, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError
        else { throw MediaError.encodeFailed("could not scale a frame") }
        return target
    }

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
            let destination = CVPixelBufferGetBaseAddress(target)
        else { throw MediaError.encodeFailed("could not map a frame") }
        let fromStride = CVPixelBufferGetBytesPerRow(source)
        let toStride = CVPixelBufferGetBytesPerRow(target)
        let originX = Int(rect.minX)
        let originY = Int(rect.minY)
        for row in 0..<height {
            memcpy(
                destination + row * toStride, from + (originY + row) * fromStride + originX * 4, width * 4)
        }
        return target
    }
}
