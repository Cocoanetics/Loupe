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

            To record across several commands, open a session and bracket them:

              loupe session open sim:booted --as phone
              loupe record start @phone
              loupe press @phone Login
              loupe record stop @phone --out login.mp4 --gif

            `--gif` also writes an animated GIF next to the video (or only the GIF \
            when `--out` ends in .gif). Frames that do not change are folded into one \
            frame held for the combined time, so a mostly still clip stays small.

            `--appstore` renders an App Store preview instead: the accepted resolution \
            for the device class, 30 fps, 15–30 s, H.264 with a silent stereo track, \
            and the simulator's status bar pinned to 9:41 while filming.

            A recording shows everything on screen, including any secret the app \
            displays. Unlike `describe`, nothing is redacted.
            """,
        subcommands: [Start.self, Stop.self])

    @OptionGroup var target: TargetOptions
    @OptionGroup var actions: ActionFlags
    @OptionGroup var output: OutputFlags

    @Option(help: "Record this long, e.g. 10s or 500ms. Without actions, the default is to run until Ctrl-C.")
    var duration: String?

    @Option(help: "Record until this shows up: `A|B`, `!X` as a failure (as in `loupe wait`).")
    var until: String?

    @Option(help: "Seconds to wait for `--until`.")
    var timeout: Double = 30

    @OptionGroup var region: RegionFlags

    @Option(help: "How long to keep recording after the actions finish, e.g. 500ms.")
    var tail: String = "500ms"

    func run() async throws {
        let parsed = try target.parsed()
        if let client = try HostRoute.client() {
            try await runOnHost(client, target: parsed)
            return
        }
        let pending = try actions.actions()
        let stop = try plan(hasActions: !pending.isEmpty)
        let kept = try region.parsed()
        var request = try output.request(defaultName: Out.timestampedName(parsed.locator, ext: "mp4"))
        if request.family == nil, request.appStore, parsed.surface == .mac { request.family = .mac }
        let limit = output.appstore ? AppStorePreview.maxDuration : RecordOptions.hardLimit
        let product = try await RecordingPipeline.produce(request) { raw in
            try await film(
                parsed, to: raw,
                Filming(record: RecordOptions(maxDuration: limit), region: kept, actions: pending, stop: stop))
        }
        output.report(product)
    }

    /// What one recording is told to do.
    private struct Filming {
        var record: RecordOptions
        var region: RecordRegion?
        var actions: [UIAction]
        var stop: RecordStop
    }

    /// Validates the flags and works out when to stop.
    private func plan(hasActions: Bool) throws -> RecordStop {
        if duration != nil, until != nil {
            throw ValidationError("--duration and --until are alternatives; give one.")
        }
        if let until { return .until(until, timeout: timeout) }
        if let duration { return .after(try DurationSpec.parse(duration)) }
        if hasActions { return .after(try DurationSpec.parse(tail)) }
        return .cancelled
    }

    /// Runs the recording, with Ctrl-C finalizing it instead of killing it mid-write.
    private func film(_ parsed: Target, to url: URL, _ filming: Filming) async throws -> RecordingResult {
        let options = target.options()
        let pin = output.appstore
        let task = Task {
            try await Loupe.record(
                parsed, to: url, options: options, record: filming.record, region: filming.region,
                actions: filming.actions, stop: filming.stop, pinStatusBar: pin)
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
}

// MARK: - record start / stop

extension Record {
    /// Start filming a live session; the session's process keeps the recorder
    /// until `record stop`.
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start recording a live session, to be stopped with `record stop`.",
            discussion: """
                Only a live session can be recorded across commands, because its process \
                is what holds the recorder in between. Open one first:

                  loupe session open sim:booted --as phone
                  loupe record start @phone

                The recording stops on its own after \(Int(RecordOptions.hardLimit)) seconds \
                if nothing stops it sooner.
                """)

        @OptionGroup var target: TargetOptions
        @OptionGroup var region: RegionFlags

        func run() async throws {
            let parsed = try target.parsed()
            let driver = try Record.session(parsed)
            try await driver.prepare()
            var options = RecordOptions()
            options.region = try region.parsed()
            _ = try await driver.startRecording(
                to: RecordingPipeline.scratchURL("loupe-session", "mov"), options: options)
            print("recording \(parsed) — stop with `loupe record stop \(parsed)`")
        }
    }

    /// Stop the session's recording and turn it into the files asked for.
    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "stop", abstract: "Stop a session's recording and write the video (and GIF).")

        @OptionGroup var target: TargetOptions
        @OptionGroup var output: OutputFlags

        func run() async throws {
            let parsed = try target.parsed()
            let driver = try Record.session(parsed)
            let request = try output.request(defaultName: Out.timestampedName(parsed.locator, ext: "mp4"))
            let recording = try await driver.stopRecording()
            output.report(try await RecordingPipeline.encode(recording, as: request))
        }
    }

    /// The session behind `@name`, or a pointer at how to get one.
    static func session(_ target: Target) throws -> LiveSessionDriver {
        guard target.surface == .live else {
            throw ValidationError(
                "`record start` and `record stop` work on a live session (@name), whose process holds the "
                    + "recording between commands. Open one with `loupe session open \(target) --as "
                    + "\(LiveSession.suggestedName(for: target))`, or record in one go: "
                    + "`loupe record \(target) --duration 10s`.")
        }
        return try LiveSessionDriver(name: target.locator)
    }
}

// MARK: - convert

struct Convert: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert",
        abstract: "Convert a recording to an animated GIF, or to an App Store preview.")

    @Argument(help: "The video to convert.")
    var input: String

    @Flag(help: "Write an animated GIF that holds still frames longer.")
    var gif = false

    @Flag(help: "Write an App Store preview: accepted resolution, 30 fps, 15–30 s, silent stereo track.")
    var appstore = false

    @Option(
        name: .customLong("appstore-device"),
        help: "Device class for --appstore: iphone, ipad or mac. Default: by the picture's shape.")
    var appstoreDevice: AppStorePreview.Family?

    @Option(help: "Output path. Defaults to the input name with .gif, or -appstore.mp4.")
    var out: String?

    @OptionGroup var gifFlags: GIFFlags

    func run() async throws {
        let source = URL(fileURLWithPath: input)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ValidationError("no such file: \(source.path)")
        }
        switch (gif, appstore) {
            case (true, false):
                let destination = out.map { URL(fileURLWithPath: $0) }
                    ?? source.deletingPathExtension().appendingPathExtension("gif")
                try await GIFFlags.convert(source, to: destination, flags: gifFlags)
            case (false, true):
                let destination = out.map { URL(fileURLWithPath: $0) }
                    ?? source.deletingPathExtension().appendingPathExtension("appstore.mp4")
                let done = try await AppStorePreview.render(from: source, to: destination, family: appstoreDevice)
                print(destination.path)
                done.notes.forEach(OutputFlags.note)
            default:
                throw ValidationError("Choose an output format: --gif or --appstore.")
        }
    }
}

extension AppStorePreview.Family: ExpressibleByArgument {}

// MARK: - Shared flags

/// `--region` / `--element`, the same on `record` and `record start`.
struct RegionFlags: ParsableArguments {
    @Option(
        help: """
            Keep only part of the screen, as x,y,w,h in points — the same space as \
            `capture --region`: origin at the top-left, x right, y down, the units \
            `describe` reports. Pixels are points × the device scale. Must lie inside \
            the screen. For a mac: window the origin is the window's top-left and the \
            region must lie inside the window; ScreenCaptureKit films only that area. For a \
            simulator it is cropped when the video is encoded, since simctl films it all.
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

    func parsed() throws -> RecordRegion? {
        if region != nil, element != nil {
            throw ValidationError("--region and --element are alternatives; give one.")
        }
        if let region { return .frame(try RecordCrop.parse(region)) }
        if let element { return .element(element, padding: padding) }
        return nil
    }
}

/// What to produce, the same on `record` and `record stop`.
struct OutputFlags: ParsableArguments {
    @Option(help: "Output path. Defaults to a timestamped .mp4 in the current directory.")
    var out: String?

    @Flag(help: "Also write an animated GIF.")
    var gif = false

    @OptionGroup var gifFlags: GIFFlags

    @Flag(help: "Render an App Store preview (accepted resolution, 30 fps, 15–30 s, silent stereo track).")
    var appstore = false

    @Option(
        name: .customLong("appstore-device"),
        help: "Device class for --appstore: iphone, ipad or mac. Default: mac for mac: targets, else by shape.")
    var appstoreDevice: AppStorePreview.Family?

    func request(defaultName: String) throws -> RecordingRequest {
        let output = URL(fileURLWithPath: out ?? defaultName)
        let gifOnly = output.pathExtension.lowercased() == "gif"
        if appstore, gifOnly {
            throw ValidationError("--appstore makes a video; give `--out` an .mp4 name (add --gif for a GIF too).")
        }
        return RecordingRequest(
            output: output, gif: (gif || gifOnly) ? gifFlags.options : nil, appStore: appstore,
            family: appstoreDevice)
    }

    /// Paths on stdout, everything else on stderr, as `capture` does.
    func report(_ product: RecordingProduct) {
        if let video = product.video { print(video.path) }
        if let gif = product.gif { print(gif.path) }
        product.notes.forEach(Self.note)
    }

    static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
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

    var options: GIFOptions {
        GIFOptions(fps: fps, maxWidth: maxWidth, threshold: threshold, loop: !noLoop)
    }

    static func convert(_ video: URL, to destination: URL, flags: GIFFlags) async throws {
        let result = try await VideoConverter.gif(from: video, options: flags.options)
        try result.data.write(to: destination, options: .atomic)
        print(destination.path)
        OutputFlags.note(
            String(
                format: "gif: %d of %d sampled frames kept over %.1fs, %@",
                result.keptFrames, result.sampledFrames, result.duration,
                ByteCountFormatter.string(fromByteCount: Int64(result.data.count), countStyle: .file)))
    }
}
