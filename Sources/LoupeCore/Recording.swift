import CoreGraphics
import Foundation

/// Knobs for a screen recording.
public struct RecordOptions: Sendable {
    /// The longest a recording may run, whatever else was asked for. A recording
    /// that is never stopped fills a disk, so every way of ending one is bounded.
    public var maxDuration: TimeInterval
    /// Set only for a driver with ``RecordingDriver/cropsRegionAtSource``: the part
    /// to film, which that driver resolves and crops while capturing.
    public var region: RecordRegion?
    /// On a simulator, show Apple's 9:41 status bar (full battery and signal)
    /// while filming and put the live one back when the recording stops — what
    /// an App Store preview wants. Ignored by drivers without a status bar.
    public var pinStatusBar = false

    public init(maxDuration: TimeInterval = RecordOptions.hardLimit) {
        self.maxDuration = min(max(maxDuration, 0.1), Self.hardLimit)
    }

    /// Ceiling no caller can raise.
    public static let hardLimit: TimeInterval = 120

    /// The note a recording carries when ``pinStatusBar`` was honoured.
    public static let statusBarPinnedNote = "status bar pinned to 9:41 while filming, restored afterwards"

    public static let `default` = RecordOptions()
}

/// A finished recording.
public struct RecordingResult: Sendable {
    public var url: URL
    /// Wall-clock seconds between the recording starting and being stopped.
    public var duration: TimeInterval
    public var bytes: Int
    public var notes: [String]
    /// The part of the screen to keep, in points, already inside the screen. The
    /// file still holds the full screen until it is cropped (see ``RecordCrop``).
    public var region: Frame?
    /// Backing scale of the filmed screen, to turn `region` into pixels.
    public var scale: Double?

    public init(url: URL, duration: TimeInterval, bytes: Int, notes: [String] = []) {
        self.url = url
        self.duration = duration
        self.bytes = bytes
        self.notes = notes
    }
}

/// A recording in progress. `stop()` finalizes the file; skipping it leaves a
/// file that does not play, so every path out of a recording must reach it.
public protocol RecordingHandle: Sendable {
    func stop() async throws -> RecordingResult
}

/// An optional capability, kept apart from ``UIDriver`` so that protocol stays at
/// its five verbs: only drivers that can film their surface conform.
public protocol RecordingDriver: UIDriver {
    func startRecording(to url: URL, options: RecordOptions) async throws -> any RecordingHandle

    /// True when the driver crops while filming and resolves `options.region`
    /// itself, instead of leaving the crop to the caller after the fact.
    var cropsRegionAtSource: Bool { get }
}

extension RecordingDriver {
    public var cropsRegionAtSource: Bool { false }
}

/// The `10s`, `500ms`, `2m` spelling of a duration. A bare number is seconds.
public enum DurationSpec {
    public static func parse(_ text: String) throws -> TimeInterval {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(suffix: String, factor: Double)] = [("ms", 0.001), ("s", 1), ("m", 60)]
        var number = trimmed
        var factor = 1.0
        for unit in units where trimmed.hasSuffix(unit.suffix) {
            number = String(trimmed.dropLast(unit.suffix.count))
            factor = unit.factor
            break
        }
        guard let value = Double(number), value.isFinite, value >= 0 else {
            throw LoupeError.failed(
                "`\(text)` is not a duration. Write it as 10s, 500ms, 2m, or a plain number of seconds.")
        }
        return value * factor
    }
}

/// What part of the screen to keep.
public enum RecordRegion: Sendable {
    /// A rectangle in target points (see ``RecordCrop``).
    case frame(Frame)
    /// An element's frame from `describe`, grown by `padding` points.
    case element(String, padding: Double)
}

/// The arithmetic of cropping a recording, kept free of AVFoundation so it can be
/// tested without a video.
///
/// Coordinates are exactly `capture --region`'s: **points**, origin at the
/// **top-left** of the screen, x to the right and y downward, the same space as
/// `UINode.frame`. Pixels are points times the backing scale (3.0 on most iPhone
/// simulators, 2.0 on iPads), which is how a recording's pixel size relates to
/// the point size `describe` and `capture` report.
public enum RecordCrop {
    /// `x,y,w,h` in points. Strict, unlike `capture --region`: a typo here would
    /// otherwise silently record the whole screen and defeat the point of asking.
    public static func parse(_ text: String) throws -> Frame {
        let numbers = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 4, numbers.allSatisfy({ $0?.isFinite == true }),
            let x = numbers[0], let y = numbers[1], let width = numbers[2], let height = numbers[3]
        else {
            throw LoupeError.failed("`\(text)` is not a region. Write it as x,y,w,h in points, e.g. 0,100,390,200.")
        }
        return Frame(x: x, y: y, width: width, height: height)
    }

    public static func padded(_ frame: Frame, by padding: Double) -> Frame {
        let amount = max(padding, 0)
        return Frame(
            x: frame.x - amount, y: frame.y - amount,
            width: frame.width + 2 * amount, height: frame.height + 2 * amount)
    }

    /// `frame` limited to a screen of `width`×`height` points, or nil when they
    /// do not overlap.
    public static func clamped(_ frame: Frame, toWidth width: Double, height: Double) -> Frame? {
        let left = max(frame.x, 0)
        let top = max(frame.y, 0)
        let right = min(frame.x + frame.width, width)
        let bottom = min(frame.y + frame.height, height)
        guard right > left, bottom > top else { return nil }
        return Frame(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The pixel rectangle to keep from a `pixelWidth`×`pixelHeight` video.
    ///
    /// Snapped outward to even numbers, because H.264 (4:2:0) cannot encode an odd
    /// size, then held inside the frame. Throws when the region is empty or does
    /// not lie inside the frame: a recording cannot be cropped to pixels it does
    /// not have, and clamping an explicit `--region` would hand back something
    /// other than what was asked for.
    public static func pixelRect(
        _ region: Frame, scale: Double, pixelWidth: Int, pixelHeight: Int
    ) throws -> CGRect {
        guard !region.isEmpty, scale > 0 else {
            throw LoupeError.failed("record region has zero width or height")
        }
        let slack = 0.5  // a half pixel of rounding in a frame that was itself rounded
        let screenWidth = Double(pixelWidth) / scale
        let screenHeight = Double(pixelHeight) / scale
        let tolerance = slack / scale
        guard region.x >= -tolerance, region.y >= -tolerance,
            region.x + region.width <= screenWidth + tolerance,
            region.y + region.height <= screenHeight + tolerance
        else {
            throw LoupeError.failed(
                String(
                    format: "region %g,%g %g×%g pt does not lie inside the %g×%g pt screen "
                        + "(origin top-left, points)",
                    region.x, region.y, region.width, region.height, screenWidth, screenHeight))
        }
        let maxX = pixelWidth - pixelWidth % 2
        let maxY = pixelHeight - pixelHeight % 2
        let left = max(0, Int((region.x * scale / 2).rounded(.down)) * 2)
        let top = max(0, Int((region.y * scale / 2).rounded(.down)) * 2)
        let right = min(maxX, Int(((region.x + region.width) * scale / 2).rounded(.up)) * 2)
        let bottom = min(maxY, Int(((region.y + region.height) * scale / 2).rounded(.up)) * 2)
        guard right - left >= 2, bottom - top >= 2 else {
            throw LoupeError.failed("record region is smaller than one pixel")
        }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
