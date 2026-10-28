import AVFoundation
import CoreGraphics
import Foundation
import LoupeCore
@testable import LoupeMedia
import Testing

@Suite struct AppStorePreviewTests {
    private func choice(_ width: Int, _ height: Int, _ family: AppStorePreview.Family? = nil) throws
        -> AppStorePreview.Choice {
        try AppStorePreview.choose(width: width, height: height, family: family)
    }

    @Test func modernIPhonesShareOneAcceptedSize() throws {
        // iPhone 17 Pro, 16 Pro Max, 16, 13 mini: all 886×1920, none letterboxed.
        for (width, height) in [(1206, 2622), (1320, 2868), (1179, 2556), (1080, 2340)] {
            let chosen = try choice(width, height)
            #expect(chosen.preset.width == 886 && chosen.preset.height == 1920)
            #expect(!chosen.letterboxed)
        }
        let landscape = try choice(2556, 1179)
        #expect(landscape.preset.width == 1920 && landscape.preset.height == 886)
    }

    @Test func homeButtonPhonesAreSixteenByNine() throws {
        let plus = try choice(1242, 2208)
        #expect(plus.preset.width == 1080 && plus.preset.height == 1920 && !plus.letterboxed)
        let small = try choice(750, 1334)
        #expect(small.preset.width == 750 && small.preset.height == 1334 && !small.letterboxed)
        #expect(try choice(1334, 750).preset.width == 1334)
    }

    @Test func iPadsFitTheFourByThreeSize() throws {
        let classic = try choice(2048, 1536)
        #expect(classic.preset.width == 1600 && classic.preset.height == 1200 && !classic.letterboxed)
        // An 11" iPad is taller than 4:3, so it is letterboxed rather than cropped.
        let air = try choice(1640, 2360)
        #expect(air.preset.width == 1200 && air.preset.height == 1600 && air.letterboxed)
    }

    @Test func macIsAlwaysLandscapeHD() throws {
        let window = try choice(1200, 800, .mac)
        #expect(window.preset == AppStorePreview.mac && window.letterboxed)
        #expect(!(try choice(1920, 1080, .mac)).letterboxed)
        #expect(throws: MediaError.self) { try choice(800, 1200, .mac) }
        // Without the hint a 16:9 window lands on the same size by shape.
        #expect(try choice(1920, 1080).preset.width == 1920)
    }

    @Test func aFamilyHintRestrictsTheTable() throws {
        let forced = try choice(1179, 2556, .ipad)
        #expect(forced.preset == AppStorePreview.iPad && forced.letterboxed)
        #expect(try choice(2048, 1536, .iphone).preset.width == 1920)
    }

    @Test func placementCoversOrFits() throws {
        let cover = AppStorePreview.placement(sourceWidth: 1179, sourceHeight: 2556, in: try choice(1179, 2556))
        #expect(abs(cover.width - 886) < 0.01)
        #expect(cover.height >= 1920 && cover.minY <= 0)
        let fit = AppStorePreview.placement(sourceWidth: 1640, sourceHeight: 2360, in: try choice(1640, 2360))
        #expect(abs(fit.height - 1600) < 0.01)
        #expect(fit.width < 1200 && fit.minX > 0)
    }

    @Test func durationIsHeldToFifteenAndCutAtThirty() {
        #expect(AppStorePreview.previewDuration(for: 2) == 15)
        #expect(AppStorePreview.previewDuration(for: 20) == 20)
        #expect(AppStorePreview.previewDuration(for: 45) == 30)
    }

    private func solid(_ gray: UInt8, width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let value = CGFloat(gray) / 255
        context.setFillColor(red: value, green: value, blue: value, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test func rendersAThirtyFPSPreviewWithASilentStereoTrack() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("appstore-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }
        // Two frames over a two-second clip, on the smallest preset to keep it quick.
        let frames = FrameQueue([
            TimedFrame(image: solid(30, width: 750, height: 1334), time: 0),
            TimedFrame(image: solid(220, width: 750, height: 1334), time: 0.5)
        ])
        let result = try await AppStorePreview.render(
            to: destination, clip: AppStorePreview.Clip(width: 750, height: 1334, duration: 2), family: nil,
            next: frames.next)
        #expect(result.duration == 15)
        #expect(result.frames == 450)
        #expect(result.notes.contains { $0.contains("held the last frame") })

        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 15) < 0.1)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await video.load(.naturalSize)
        #expect(Int(size.width) == 750 && Int(size.height) == 1334)
        let rate = try await video.load(.nominalFrameRate)
        #expect(abs(Double(rate) - 30) < 0.5)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let formats = try await audio.load(.formatDescriptions)
        let channels = formats.first.flatMap { $0.audioStreamBasicDescription?.mChannelsPerFrame }
        #expect(channels == 2)
    }

    @Test func renderingNothingIsAnError() async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("appstore-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }
        await #expect(throws: MediaError.self) {
            _ = try await AppStorePreview.render(
                to: destination, clip: AppStorePreview.Clip(width: 750, height: 1334, duration: 2), family: nil
            ) { nil }
        }
    }

    @Test func gifOnlyRequestsWriteNoVideo() {
        let gif = RecordingRequest(output: URL(fileURLWithPath: "/tmp/x/clip.gif"))
        #expect(gif.gifOnly && gif.videoURL == nil && gif.gifURL?.lastPathComponent == "clip.gif")
        let both = RecordingRequest(output: URL(fileURLWithPath: "/tmp/x/clip.mp4"), gif: GIFOptions())
        #expect(both.videoURL?.lastPathComponent == "clip.mp4" && both.gifURL?.lastPathComponent == "clip.gif")
        let video = RecordingRequest(output: URL(fileURLWithPath: "/tmp/x/clip.mp4"))
        #expect(video.gifURL == nil)
    }
}

/// Frames handed out in order from whichever queue the writer asks on.
private final class FrameQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [TimedFrame]
    init(_ frames: [TimedFrame]) { remaining = frames }
    func next() -> TimedFrame? {
        lock.withLock { remaining.isEmpty ? nil : remaining.removeFirst() }
    }
}

@Suite struct RecordingPipelineTests {
    @Test func theRawRecordingIsKeptWhenNoVideoCanBeWritten() async throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("raw-\(UUID()).mov")
        try Data("not a movie".utf8).write(to: raw)
        defer { try? FileManager.default.removeItem(at: raw) }
        // A directory nothing can be written into, so the fallback copy fails too.
        let locked = FileManager.default.temporaryDirectory
            .appendingPathComponent("locked-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: locked)
        }
        let recording = RecordingResult(url: raw, duration: 1, bytes: 11)
        let request = RecordingRequest(output: locked.appendingPathComponent("clip.mp4"))
        do {
            _ = try await RecordingPipeline.encode(recording, as: request)
            Issue.record("a missing video was reported as success")
        } catch {
            #expect("\(error)".contains(raw.path))
        }
        #expect(FileManager.default.fileExists(atPath: raw.path))
    }

    @Test func produceKeepsTheRawRecordingItsErrorNames() async throws {
        let locked = FileManager.default.temporaryDirectory
            .appendingPathComponent("locked-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: locked)
        }
        var filmed: URL?
        let request = RecordingRequest(output: locked.appendingPathComponent("c.mp4"))
        do {
            _ = try await RecordingPipeline.produce(request) { raw in
                try Data("not a movie".utf8).write(to: raw)
                filmed = raw
                return RecordingResult(url: raw, duration: 1, bytes: 11)
            }
            Issue.record("a missing video was reported as success")
        } catch {
            let raw = try #require(filmed)
            defer { try? FileManager.default.removeItem(at: raw) }
            #expect("\(error)".contains(raw.path))
            // The path in the error must still be there to pick up.
            #expect(FileManager.default.fileExists(atPath: raw.path))
        }
    }

    @Test func produceCleansUpWhenFilmingItselfFails() async throws {
        var filmed: URL?
        let request = RecordingRequest(output: URL(fileURLWithPath: "/tmp/x.mp4"))
        await #expect(throws: LoupeError.self) {
            _ = try await RecordingPipeline.produce(request) { raw in
                try Data("half".utf8).write(to: raw)
                filmed = raw
                throw LoupeError.failed("simctl died")
            }
        }
        let raw = try #require(filmed)
        #expect(!FileManager.default.fileExists(atPath: raw.path))
    }

    @Test func anUnreadableRecordingStillBecomesAVideoByCopy() async throws {
        // Transcoding garbage fails; the copy fallback keeps it, as before.
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("raw-\(UUID()).mov")
        try Data("not a movie".utf8).write(to: raw)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("copy-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let product = try await RecordingPipeline.encode(
            RecordingResult(url: raw, duration: 1, bytes: 11), as: RecordingRequest(output: out))
        #expect(product.bytes == 11)
        #expect(product.notes.contains { $0.contains("kept the original") })
        #expect(!FileManager.default.fileExists(atPath: raw.path))
    }
}
