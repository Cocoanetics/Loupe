import ArgumentParser
import Foundation
import LoupeKit
import LoupeMedia

// MARK: - record

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record a simulator to video, optionally as an animated GIF.",
        discussion: """
            Records while the actions run, keeps going for a short tail, then stops:

              loupe record sim:booted --press Login --out tap.mp4

            With no actions, give `--duration` or `--until`, or press Ctrl-C to stop; \
            the file is finalized either way. Nothing runs longer than \(Int(RecordOptions.hardLimit)) seconds.

            `--gif` also writes an animated GIF next to the video (or only the GIF \
            when `--out` ends in .gif). Frames that do not change are folded into one \
            frame held for the combined time, so a mostly still clip stays small.

            A recording shows everything on screen, including any secret the app \
            displays. Unlike `describe`, nothing is redacted.
            """)

    @OptionGroup var target: TargetOptions
    @OptionGroup var actions: ActionFlags
    @OptionGroup var gifFlags: GIFFlags

    @Option(help: "Output path. Defaults to a timestamped .mp4 in the current directory.")
    var out: String?

    @Option(help: "Record this long, e.g. 10s or 500ms. Without actions, the default is to run until Ctrl-C.")
    var duration: String?

    @Option(help: "Record until this shows up: `A|B`, `!X` as a failure (as in `loupe wait`).")
    var until: String?

    @Option(help: "Seconds to wait for `--until`.")
    var timeout: Double = 30

    @Option(
        help: """
            Keep only part of the screen, as x,y,w,h in points — the same space as \
            `capture --region`: origin at the top-left, x right, y down, the units \
            `describe` reports. Pixels are points × the device scale. Must lie inside \
            the screen. Cropped when the video is encoded, since simctl films it all.
            """)
    var region: String?

    @Option(
        help: """
            Keep only this element (handle, identifier or label), cropped to its frame \
            from `describe` as read when recording starts. Clamped to the screen.
            """)
    var element: String?

    @Option(help: "Points added around `--element` on every side.")
    var padding: Double = 8

    @Option(help: "How long to keep recording after the actions finish, e.g. 500ms.")
    var tail: String = "500ms"

    @Flag(help: "Also write an animated GIF.")
    var gif = false

    func run() async throws {
        let parsed = try target.parsed()
        let pending = try actions.actions()
        if duration != nil, until != nil {
            throw ValidationError("--duration and --until are alternatives; give one.")
        }
        if region != nil, element != nil {
            throw ValidationError("--region and --element are alternatives; give one.")
        }
        let kept: RecordRegion?
        if let region {
            kept = .frame(try RecordCrop.parse(region))
        } else if let element {
            kept = .element(element, padding: padding)
        } else {
            kept = nil
        }
        let stop: RecordStop
        if let until {
            let (nodes, failures) = WaitCommand.split(until)
            stop = .until(nodes: nodes, failIf: failures, timeout: timeout)
        } else if let duration {
            stop = .after(try DurationSpec.parse(duration))
        } else if !pending.isEmpty {
            stop = .after(try DurationSpec.parse(tail))
        } else {
            stop = .cancelled
        }

        let gifOnly = out?.lowercased().hasSuffix(".gif") == true
        // `--out run.gif` says what is wanted; the flag is not needed too.
        let wantsGIF = gif || gifOnly
        let requested = out ?? Out.timestampedName(parsed.locator, ext: "mp4")
        let videoURL: URL
        let gifURL: URL?
        if gifOnly {
            videoURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("loupe-record-\(UUID().uuidString).mp4")
            gifURL = URL(fileURLWithPath: requested)
        } else {
            videoURL = URL(fileURLWithPath: requested)
            gifURL = wantsGIF ? videoURL.deletingPathExtension().appendingPathExtension("gif") : nil
        }
        defer { if gifOnly { try? FileManager.default.removeItem(at: videoURL) } }
        // simctl's own encode is tuned for motion; it is re-encoded for a screen below.
        let rawURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-raw-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: rawURL) }

        let task = Task {
            try await Loupe.record(
                parsed, to: rawURL, options: target.options(), region: kept, actions: pending, stop: stop)
        }
        // Ctrl-C finalizes the recording instead of killing it mid-write.
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { task.cancel() }
        interrupt.resume()
        let result = try await task.value
        interrupt.cancel()
        let crop = result.region.flatMap { frame in result.scale.map { ScreenCrop(region: frame, scale: $0) } }

        do {
            let transcoded = try await ScreenContentTranscoder.transcode(from: rawURL, to: videoURL, crop: crop)
            FileHandle.standardError.write(
                Data(
                    "h264: \(transcoded.writtenFrames) of \(transcoded.sourceFrames) frames written (variable frame rate)\n"
                        .utf8))
        } catch {
            // Never lose a recording to a tuning step: keep simctl's own file.
            try? FileManager.default.removeItem(at: videoURL)
            try FileManager.default.copyItem(at: rawURL, to: videoURL)
            FileHandle.standardError.write(
                Data("note: could not optimize the video (\(error.localizedDescription)); kept the original encode\(crop == nil ? "" : ", NOT cropped")\n".utf8))
        }
        if !gifOnly { print(videoURL.path) }
        FileHandle.standardError.write(
            Data(
                String(
                    format: "recorded %.1fs, %@\n", result.duration,
                    ByteCountFormatter.string(fromByteCount: Int64(result.bytes), countStyle: .file)
                ).utf8))
        if let gifURL {
            try await GIFFlags.convert(
                videoURL, to: gifURL, flags: gifFlags)
        }
    }
}

// MARK: - convert

struct Convert: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert",
        abstract: "Convert a recording to an animated GIF that holds still frames longer.")

    @Argument(help: "The video to convert.")
    var input: String

    @Flag(help: "Write an animated GIF.")
    var gif = false

    @Option(help: "Output path. Defaults to the input name with a .gif extension.")
    var out: String?

    @OptionGroup var gifFlags: GIFFlags

    func run() async throws {
        guard gif else {
            throw ValidationError("Choose an output format: --gif.")
        }
        let source = URL(fileURLWithPath: input)
        let destination = out.map { URL(fileURLWithPath: $0) }
            ?? source.deletingPathExtension().appendingPathExtension("gif")
        try await GIFFlags.convert(source, to: destination, flags: gifFlags)
    }
}

struct GIFFlags: ParsableArguments {
    @Option(help: "GIF: frames sampled per second of video.")
    var fps: Double = 10

    @Option(name: .customLong("max-width"), help: "GIF: output width in pixels.")
    var maxWidth: Int = 800

    @Option(help: "GIF: how different a frame must be (0–1, mean luminance) to count as changed.")
    var threshold: Double = 0.002

    @Flag(name: .customLong("no-loop"), help: "GIF: play once instead of looping.")
    var noLoop = false

    static func convert(_ video: URL, to destination: URL, flags: GIFFlags) async throws {
        let result = try await VideoConverter.gif(
            from: video,
            options: GIFOptions(
                fps: flags.fps, maxWidth: flags.maxWidth, threshold: flags.threshold,
                loop: !flags.noLoop))
        try result.data.write(to: destination, options: .atomic)
        print(destination.path)
        FileHandle.standardError.write(
            Data(
                String(
                    format: "gif: %d of %d sampled frames kept over %.1fs, %@\n",
                    result.keptFrames, result.sampledFrames, result.duration,
                    ByteCountFormatter.string(
                        fromByteCount: Int64(result.data.count), countStyle: .file)
                ).utf8))
    }
}
