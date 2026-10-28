import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import LoupeCore
import VideoToolbox

/// Renders a recording the way App Store Connect wants an app preview.
///
/// The numbers come from Apple's "App preview specifications" page in App Store
/// Connect Help (read 2026-10-28): an *accepted* resolution per display class
/// rather than the device's own, H.264 up to High Profile Level 4.0 at 10–12 Mbps,
/// at most 30 fps, 15 to 30 seconds, and stereo 256 kbps AAC at 44.1 or 48 kHz.
/// The page does not say an audio track is required, but uploads without one are
/// widely reported to fail processing, so a silent stereo track is always written.
public enum AppStorePreview {

    /// Which product page the preview is for. Decides the resolution table.
    public enum Family: String, CaseIterable, Sendable {
        case iphone
        case ipad
        case mac
    }

    /// One accepted resolution, in the orientation it will be used in.
    public struct Preset: Sendable, Equatable {
        public var name: String
        public var width: Int
        public var height: Int

        public init(name: String, width: Int, height: Int) {
            self.name = name
            self.width = width
            self.height = height
        }

        var aspect: Double { Double(width) / Double(height) }

        /// The same preset turned to match a picture's orientation.
        func oriented(portrait: Bool) -> Preset {
            guard (height > width) != portrait else { return self }
            return Preset(name: name, width: height, height: width)
        }
    }

    /// Every modern iPhone (6.9" down to 5.8") shares one accepted size.
    public static let iPhone = Preset(name: "iPhone 6.9″–5.8″", width: 886, height: 1920)
    /// Home-button iPhones with a 16:9 screen (5.5", and 4" scaled up).
    public static let iPhone16by9 = Preset(name: "iPhone 5.5″", width: 1080, height: 1920)
    /// The 4.7" iPhone is the one class whose accepted size is its own size.
    public static let iPhone47 = Preset(name: "iPhone 4.7″", width: 750, height: 1334)
    /// Every iPad: 13" and 12.9" down to 10.5", with 9.7" scaled down from it.
    public static let iPad = Preset(name: "iPad", width: 1200, height: 1600)
    /// Mac and Apple TV. Landscape only.
    public static let mac = Preset(name: "Mac", width: 1920, height: 1080)

    public static let frameRate = 30
    public static let minDuration: TimeInterval = 15
    public static let maxDuration: TimeInterval = 30
    /// Inside Apple's 10–12 Mbps target.
    public static let bitRate = 11_000_000
    public static let audioSampleRate = 44_100.0
    public static let audioBitRate = 256_000

    /// A picture whose shape is this far (relative) from the preset's is scaled
    /// to fill it and trimmed at the edges — a couple of pixels, for every modern
    /// iPhone. Anything further apart is letterboxed instead, so nothing is lost.
    public static let coverTolerance = 0.01

    /// A preset and how the picture is placed in it.
    public struct Choice: Sendable, Equatable {
        public var preset: Preset
        /// Scaled to fit with black bars, rather than scaled to fill.
        public var letterboxed: Bool
    }

    /// What is known about the source before any frame is read.
    public struct Clip: Sendable {
        public var width: Int
        public var height: Int
        public var duration: TimeInterval

        public init(width: Int, height: Int, duration: TimeInterval) {
            self.width = width
            self.height = height
            self.duration = duration
        }
    }

    /// The accepted size for a picture of `width`×`height` pixels.
    ///
    /// `family` restricts the table; nil chooses among iPhone and iPad sizes by
    /// the picture's shape, which is right for a simulator but not for a Mac
    /// window, whose shape is whatever the user dragged it to.
    public static func choose(width: Int, height: Int, family: Family?) throws -> Choice {
        guard width > 0, height > 0 else { throw MediaError.noFrames }
        let portrait = height > width
        let aspect = Double(width) / Double(height)
        if family == .mac {
            guard !portrait else {
                throw MediaError.encodeFailed(
                    "Mac previews are landscape only, and this picture is \(width)×\(height) (portrait)")
            }
            return Choice(preset: mac, letterboxed: deviation(aspect, from: mac) > coverTolerance)
        }
        if family != .ipad, (width, height) == (750, 1334) || (width, height) == (1334, 750) {
            return Choice(preset: iPhone47.oriented(portrait: portrait), letterboxed: false)
        }
        let candidates: [Preset]
        switch family {
            case .iphone: candidates = [iPhone, iPhone16by9]
            case .ipad: candidates = [iPad]
            case .mac, nil: candidates = [iPhone, iPhone16by9, iPad]
        }
        let oriented = candidates.map { $0.oriented(portrait: portrait) }
        guard let best = oriented.min(by: { deviation(aspect, from: $0) < deviation(aspect, from: $1) }) else {
            throw MediaError.noFrames
        }
        return Choice(preset: best, letterboxed: deviation(aspect, from: best) > coverTolerance)
    }

    private static func deviation(_ aspect: Double, from preset: Preset) -> Double {
        abs(aspect - preset.aspect) / preset.aspect
    }

    /// Where a `sourceWidth`×`sourceHeight` picture lands inside the preset.
    public static func placement(sourceWidth: Int, sourceHeight: Int, in choice: Choice) -> CGRect {
        let target = choice.preset
        let byWidth = Double(target.width) / Double(sourceWidth)
        let byHeight = Double(target.height) / Double(sourceHeight)
        let scale = choice.letterboxed ? min(byWidth, byHeight) : max(byWidth, byHeight)
        let width = Double(sourceWidth) * scale
        let height = Double(sourceHeight) * scale
        return CGRect(
            x: (Double(target.width) - width) / 2, y: (Double(target.height) - height) / 2,
            width: width, height: height)
    }

    /// How long the preview will be for a clip of `duration`: held to 15 s,
    /// cut at 30 s.
    public static func previewDuration(for duration: TimeInterval) -> TimeInterval {
        min(max(duration, minDuration), maxDuration)
    }

    public struct Result: Sendable {
        public var choice: Choice
        public var duration: TimeInterval
        public var frames: Int
        public var notes: [String]
    }

    /// Reads `source` and writes the preview to `destination`.
    public static func render(
        from source: URL, to destination: URL, crop: ScreenCrop? = nil, family: Family? = nil
    ) async throws -> Result {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.unreadable("\(source.lastPathComponent) has no video track")
        }
        let duration = try await asset.load(.duration).seconds
        let size = try await track.load(.naturalSize)
        let sourceWidth = Int(size.width.rounded())
        let sourceHeight = Int(size.height.rounded())
        guard sourceWidth > 0, sourceHeight > 0, duration.isFinite, duration > 0 else {
            throw MediaError.noFrames
        }
        var rect: CGRect?
        if let crop {
            rect = try RecordCrop.pixelRect(
                crop.region, scale: crop.scale, pixelWidth: sourceWidth, pixelHeight: sourceHeight)
        }
        let kept = rect ?? CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
        let frames = try FrameReader(asset: asset, track: track, crop: rect)
        defer { frames.cancel() }
        return try await render(
            to: destination, clip: Clip(width: Int(kept.width), height: Int(kept.height), duration: duration),
            family: family, next: frames.next)
    }

    /// The encoder proper, fed frames in time order by `next` (nil when there
    /// are no more). Each output tick shows the latest source frame at or before
    /// it, so a still screen costs a repeat of the same picture, and the last
    /// one is held until the preview is long enough.
    static func render(
        to destination: URL, clip: Clip, family: Family?, next: @escaping @Sendable () throws -> TimedFrame?
    ) async throws -> Result {
        let choice = try choose(width: clip.width, height: clip.height, family: family)
        let target = previewDuration(for: clip.duration)
        let totalFrames = Int((target * Double(frameRate)).rounded())
        guard let first = try next() else { throw MediaError.noFrames }
        let writer = try Writer(destination: destination, preset: choice.preset)
        try await writer.write(
            frames: totalFrames, seconds: target, choice: choice, first: first, next: next)

        var notes = ["appstore: \(choice.preset.name) preset, \(choice.preset.width)×\(choice.preset.height), 30 fps"]
        if choice.letterboxed {
            notes.append(
                "appstore: the \(clip.width)×\(clip.height) picture is not the preset's shape, so it is "
                    + "letterboxed; record a device of that class for an edge-to-edge preview")
        }
        if clip.duration < minDuration {
            notes.append(
                String(format: "appstore: held the last frame to reach 15s (recorded %.1fs)", clip.duration))
        } else if clip.duration > maxDuration {
            notes.append(String(format: "appstore: cut at 30s (recorded %.1fs)", clip.duration))
        }
        return Result(choice: choice, duration: target, frames: totalFrames, notes: notes)
    }
}
