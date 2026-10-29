import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import LoupeCore
@testable import LoupeMedia
import Testing

// The 5K encodes take about a second; a stuck one fails here instead of holding up CI.
// One at a time, so CPU scaling at 5K doesn't starve the rest of the suite on a small runner.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ScreenContentTranscoderTests {
    /// Built once and shared; tests only read it.
    private static let sharedFiveK = Task { try await fiveKMovie() }

    @Test func picturesPastTheH264LimitAreScaledToFit() {
        #expect(ScreenContentTranscoder.encodedSize(width: 5120, height: 2880) == (4096, 2304))
        #expect(ScreenContentTranscoder.encodedSize(width: 2880, height: 5120) == (2304, 4096))
        // 6K: the long edge alone would leave it too large in area.
        let sixK = ScreenContentTranscoder.encodedSize(width: 6016, height: 3384)
        #expect(sixK.width <= 4096 && sixK.width * sixK.height <= 4096 * 2304)
    }

    @Test func picturesThatFitKeepTheirNativeSize() {
        #expect(ScreenContentTranscoder.encodedSize(width: 1940, height: 1244) == (1940, 1244))
        #expect(ScreenContentTranscoder.encodedSize(width: 4096, height: 2304) == (4096, 2304))
        #expect(ScreenContentTranscoder.encodedSize(width: 1667, height: 2421) == (1667, 2421))
    }

    @Test func scaledSidesAreEven() {
        for (width, height) in [(4097, 1000), (5121, 2881), (4999, 4999), (8191, 3)] {
            let size = ScreenContentTranscoder.encodedSize(width: width, height: height)
            #expect(size.width % 2 == 0 && size.height % 2 == 0)
            #expect(size.width <= 4096 && size.height <= 4096)
        }
    }

    @Test func aRotationIsKeptAndItsTranslationScaled() {
        let quarter = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 2880, ty: 0)
        let scaled = ScreenContentTranscoder.scaled(
            quarter, from: CGSize(width: 5120, height: 2880), toWidth: 4096, height: 2304)
        #expect(scaled == CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 2304, ty: 0))
        let half = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 5120, ty: 2880)
        #expect(
            ScreenContentTranscoder.scaled(
                half, from: CGSize(width: 5120, height: 2880), toWidth: 4096, height: 2304)
                == CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 4096, ty: 2304))
        // Not scaled: whatever the track had, untouched.
        #expect(
            ScreenContentTranscoder.scaled(
                quarter, from: CGSize(width: 1940, height: 1244), toWidth: 1940, height: 1244) == quarter)
    }

    @Test func aRotatedFiveKSourceKeepsItsPictureInView() async throws {
        let quarter = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 2880, ty: 0)
        let source = try await Self.fiveKMovie(transform: quarter)
        defer { try? FileManager.default.removeItem(at: source) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("rot-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: out) }

        _ = try await ScreenContentTranscoder.transcode(from: source, to: out)
        let track = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
        let transform = try await track.load(.preferredTransform)
        let shown = CGRect(x: 0, y: 0, width: 4096, height: 2304).applying(transform)
        #expect(shown == CGRect(x: 0, y: 0, width: 2304, height: 4096))
    }

    @Test func settingsAreCheckedBeforeTheInputIsMade() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("settings-\(UUID()).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var notes: [String] = []
        // At 5K the quality setting is what raised; the answer must be settings
        // the input takes, or a Swift error.
        do {
            let settings = try ScreenContentTranscoder.applicableSettings(
                width: 5120, height: 2880, writer: writer, notes: &notes)
            _ = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        } catch {
            #expect(error is MediaError)
        }
    }

    @Test func aFiveKSourceIsScaledAndEncoded() async throws {
        let source = try await Self.sharedFiveK.value
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("5k-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: out) }

        let done = try await ScreenContentTranscoder.transcode(from: source, to: out)
        #expect(done.width == 4096 && done.height == 2304)
        #expect(done.writtenFrames >= 2)
        #expect(done.notes.contains { $0.contains("5120×2880 → 4096×2304") })
        let track = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == 4096 && Int(size.height) == 2304)
    }

    @Test func aFiveKSourceFitsAMaxSizePreset() async throws {
        let source = try await Self.sharedFiveK.value
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("1080p-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: out) }

        let done = try await ScreenContentTranscoder.transcode(
            from: source, to: out, maxSize: try MaxSize.parse("1080p"))
        #expect(done.width == 1920 && done.height == 1080)
        #expect(done.notes.contains("h264: scaled 5120×2880 → 1920×1080 (--max-size 1080p)"))
        #expect(!done.notes.contains { $0.contains("H.264 limit") })
        let track = try #require(try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == 1920 && Int(size.height) == 1080)
    }

    @Test func aMaxSizeVideoNeverFallsBackToTheUncappedOriginal() async throws {
        // Not a movie, so the transcode fails; the plain fallback would copy it as is.
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("raw-bad-\(UUID()).mov")
        try Data("not a movie".utf8).write(to: raw)
        defer { try? FileManager.default.removeItem(at: raw) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("capped-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: out) }

        let request = RecordingRequest(output: out, maxSize: try MaxSize.parse("720p"))
        await #expect {
            _ = try await RecordingPipeline.encode(RecordingResult(url: raw, duration: 1, bytes: 11), as: request)
        } throws: { error in
            error.localizedDescription.contains("--max-size 720p")
                && error.localizedDescription.contains("raw recording was kept")
        }
        #expect(FileManager.default.fileExists(atPath: raw.path))
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func aPresetTurnsWithATrackRotatedToPortrait() {
        let quarter = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 2880, ty: 0)
        let preset = MaxSize(width: 1920, height: 1080, followsOrientation: true)
        // Shown as 2880×5120, so it fits 1080×1920; in the track's own pixels that is 1920×1080.
        #expect(
            ScreenContentTranscoder.boxed(CGSize(width: 5120, height: 2880), into: preset, transform: quarter)
                == (1920, 1080))
        let literal = MaxSize(width: 1920, height: 1080)
        #expect(
            ScreenContentTranscoder.boxed(CGSize(width: 5120, height: 2880), into: literal, transform: quarter)
                == (1080, 606))
    }

    @Test func aPortraitGIFFitsTheDefaultBox() async throws {
        let source = try await Self.movie(width: 1668, height: 2420)
        defer { try? FileManager.default.removeItem(at: source) }

        let result = try await VideoConverter.gif(from: source)
        let image = try #require(
            CGImageSourceCreateWithData(result.data as CFData, nil).flatMap {
                CGImageSourceCreateImageAtIndex($0, 0, nil)
            })
        // Exactly the fitted box: a GIF need not round to even, and no side comes out short.
        let fitted = MaxSize.gifDefault.fit(CGSize(width: 1668, height: 2420), evenDimensions: false)
        #expect(CGSize(width: image.width, height: image.height) == fitted)
        #expect(image.width == 551 && image.height == 800)
        // The note names the frames as written, not the box they were fitted to.
        #expect(result.notes.contains("gif: scaled 1668×2420 → \(image.width)×\(image.height) (--max-size 800x800)"))
    }

    @Test func aCropIsScaledOnlyWhenItIsStillTooLarge() async throws {
        let source = try await Self.sharedFiveK.value
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("crop-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: out) }

        // Points at 2×: 2400 points wide is 4800 pixels, still past the limit.
        let wide = ScreenCrop(region: Frame(x: 0, y: 0, width: 2400, height: 1200), scale: 2)
        let large = try await ScreenContentTranscoder.transcode(from: source, to: out, crop: wide)
        #expect(large.width <= 4096 && large.width < 4800)
        #expect(!large.notes.isEmpty)

        let small = ScreenCrop(region: Frame(x: 100, y: 100, width: 800, height: 600), scale: 2)
        let native = try await ScreenContentTranscoder.transcode(from: source, to: out, crop: small)
        #expect(native.width == 1600 && native.height == 1200)
        #expect(native.notes.isEmpty)
    }

    @Test func thePipelineNamesTheScalingAndConsumesTheRawFile() async throws {
        // The pipeline consumes its raw file, so it gets a copy of the shared one.
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("raw-5k-\(UUID()).mov")
        try FileManager.default.copyItem(at: try await Self.sharedFiveK.value, to: raw)
        defer { try? FileManager.default.removeItem(at: raw) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("pipe-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: out) }

        let product = try await RecordingPipeline.encode(
            RecordingResult(url: raw, duration: 0.5, bytes: 0), as: RecordingRequest(output: out))
        #expect(product.notes.contains { $0.contains("(H.264 limit)") })
        #expect(!product.notes.contains { $0.contains("kept the original") })
        #expect(!FileManager.default.fileExists(atPath: raw.path))
    }

    private static func fiveKMovie(transform: CGAffineTransform = .identity) async throws -> URL {
        try await movie(width: 5120, height: 2880, transform: transform)
    }

    /// Two different solid frames, written the way the Mac recorder writes its
    /// raw file: plain H.264 with no compression properties.

    private static func movie(width: Int, height: Int, transform: CGAffineTransform = .identity)
        async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("raw-\(width)-\(UUID()).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for (index, gray) in [UInt8(30), 220].enumerated() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let pool = try #require(adaptor.pixelBufferPool)
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            let buffer = try #require(made)
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(
                CVPixelBufferGetBaseAddress(buffer), Int32(gray),
                CVPixelBufferGetBytesPerRow(buffer) * height)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 4)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 4))
        await writer.finishWriting()
        try #require(writer.status == .completed, "\(String(describing: writer.error))")
        return url
    }
}
