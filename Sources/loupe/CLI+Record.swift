import ArgumentParser
import Foundation
import LoupeKit
import LoupeMedia

// MARK: - record

struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record a simulator or Mac window to video, optionally as an animated GIF.",
        discussion: """
            Records while the actions run, keeps going for a short tail, then stops:

              loupe record sim:booted --press Login --out tap.mp4
              loupe record mac:Notes --duration 5s --out notes.mp4

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
        let (kept, stop) = try plan(hasActions: !pending.isEmpty)

        let gifOnly = out?.lowercased().hasSuffix(".gif") == true
        let requested = out ?? Out.timestampedName(parsed.locator, ext: "mp4")
        let videoURL = gifOnly ? Self.scratchURL("loupe-record", "mp4") : URL(fileURLWithPath: requested)
        // `--out run.gif` says what is wanted; the flag is not needed too.
        var gifURL: URL?
        if gifOnly {
            gifURL = URL(fileURLWithPath: requested)
        } else if gif {
            gifURL = videoURL.deletingPathExtension().appendingPathExtension("gif")
        }
        defer { if gifOnly { try? FileManager.default.removeItem(at: videoURL) } }
        // simctl's own encode is tuned for motion; it is re-encoded for a screen below.
        let rawURL = Self.scratchURL("loupe-raw", "mov")
        defer { try? FileManager.default.removeItem(at: rawURL) }

        let result = try await film(parsed, to: rawURL, region: kept, actions: pending, stop: stop)
        let crop = result.region.flatMap { frame in result.scale.map { ScreenCrop(region: frame, scale: $0) } }
        try await encode(rawURL, to: videoURL, crop: crop)

        if !gifOnly { print(videoURL.path) }
        let size = ByteCountFormatter.string(fromByteCount: Int64(result.bytes), countStyle: .file)
        note(String(format: "recorded %.1fs, %@", result.duration, size))
        if let gifURL {
            try await GIFFlags.convert(videoURL, to: gifURL, flags: gifFlags)
        }
    }

    private static func scratchURL(_ prefix: String, _ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString).\(ext)")
    }

    private func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// Validates the flags and works out what to keep and when to stop.
    private func plan(hasActions: Bool) throws -> (RecordRegion?, RecordStop) {
        if duration != nil, until != nil {
            throw ValidationError("--duration and --until are alternatives; give one.")
        }
        if region != nil, element != nil {
            throw ValidationError("--region and --element are alternatives; give one.")
        }
        var kept: RecordRegion?
        if let region {
            kept = .frame(try RecordCrop.parse(region))
        } else if let element {
            kept = .element(element, padding: padding)
        }
        if let until {
            let (nodes, failures) = WaitCommand.split(until)
            return (kept, .until(nodes: nodes, failIf: failures, timeout: timeout))
        }
        if let duration { return (kept, .after(try DurationSpec.parse(duration))) }
        if hasActions { return (kept, .after(try DurationSpec.parse(tail))) }
        return (kept, .cancelled)
    }

    /// Runs the recording, with Ctrl-C finalizing it instead of killing it mid-write.
    private func film(
        _ parsed: Target, to url: URL, region: RecordRegion?, actions: [UIAction], stop: RecordStop
    ) async throws -> RecordingResult {
        let options = target.options()
        let task = Task {
            try await Loupe.record(
                parsed, to: url, options: options, region: region, actions: actions, stop: stop)
        }
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { task.cancel() }
        interrupt.resume()
        defer { interrupt.cancel() }
        do {
            return try await task.value
        } catch is CancellationError {
            // Ctrl-C before filming began: nothing was recorded, and simctl is gone.
            throw LoupeError.failed("interrupted before the recording started")
        }
    }

    private func encode(_ raw: URL, to video: URL, crop: ScreenCrop?) async throws {
        do {
            let done = try await ScreenContentTranscoder.transcode(from: raw, to: video, crop: crop)
            note("h264: \(done.writtenFrames) of \(done.sourceFrames) frames written (variable frame rate)")
        } catch {
            // Never lose a recording to a tuning step: keep simctl's own file.
            try? FileManager.default.removeItem(at: video)
            try FileManager.default.copyItem(at: raw, to: video)
            let uncropped = crop == nil ? "" : ", NOT cropped"
            note(
                "note: could not optimize the video (\(error.localizedDescription)); "
                    + "kept the original encode\(uncropped)")
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
