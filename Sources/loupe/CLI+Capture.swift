import ArgumentParser
import Foundation
import LoupeKit

// MARK: - capture

struct Capture: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture", abstract: "Screenshot a target.")

    @OptionGroup var target: TargetOptions
    @OptionGroup var flags: CaptureFlags
    @OptionGroup var actions: ActionFlags

    func run() async throws {
        let parsed = try target.parsed()
        let pending = try actions.actions()
        let shot: LoupeCore.Capture
        if pending.isEmpty {
            shot = try await Loupe.capture(
                parsed, options: target.options(), capture: flags.captureOptions())
        } else {
            let (_, captured) = try await Loupe.act(
                parsed, actions: pending, options: target.options(),
                captureAfter: flags.captureOptions())
            guard let captured else { throw LoupeError.failed("no capture produced") }
            shot = captured
        }
        var image = shot.png
        if flags.annotate {
            let annotated = try await Loupe.annotatedCapture(
                parsed, options: target.options(), capture: flags.captureOptions())
            image = annotated.png
            for annotation in annotated.annotations {
                FileHandle.standardError.write(
                    Data("  \(annotation.caption)  → \(annotation.id)\n".utf8))
            }
        }
        let data = try flags.postProcess(image)
        let url = try Out.write(
            data, to: flags.out, fallback: Out.timestampedName(parsed.locator))
        print("\(url.path)")
        let size = "\(Int(shot.pointSize.width))×\(Int(shot.pointSize.height))pt"
        FileHandle.standardError.write(
            Data("captured \(size) @\(shot.scale)x — \(shot.target)\n".utf8))
        for note in shot.notes {
            FileHandle.standardError.write(Data("note: \(note)\n".utf8))
        }
    }
}

// MARK: - describe

struct Describe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "describe",
        abstract: "Print the target's element tree.")

    @OptionGroup var target: TargetOptions

    @Option(help: "Maximum tree depth.")
    var depth: Int = 24

    @Flag(name: .customLong("all"), help: "Include layout-only nodes, not just interesting ones.")
    var all = false

    @Option(help: "Only show elements matching this text.")
    var filter: String?

    @Option(help: "Start at this handle instead of the top, to open one branch.")
    var at: String?

    @Flag(help: "Expand the whole macOS menu bar instead of collapsing it.")
    var menus = false

    @Flag(help: "Show what each element advertises it can do.")
    var actions = false

    @Flag(help: "Emit JSON instead of an indented outline.")
    var json = false

    func run() async throws {
        let nodes = try await Loupe.describe(
            try target.parsed(),
            options: target.options(),
            describe: DescribeOptions(
                maxDepth: depth, interestingOnly: !all, filter: filter,
                // A filter is a search, and a search that quietly skips the
                // menu bar would report "no match" for something that is right
                // there — the exact silent omission this renderer exists to stop.
                scope: (menus || filter != nil) ? .all : .primary, root: at))
        // A field's value can hold what we just typed into it, so the tree gets the
        // same scrubbing as action output.
        if json {
            print(Secrets.redact(try Out.json(nodes)))
        } else {
            print(Secrets.redact(Outline.render(nodes, actions: actions)))
        }
    }

}

// MARK: - act

struct Act: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "act",
        abstract: "Do something to a target, optionally screenshotting the result.")

    @OptionGroup var target: TargetOptions
    @OptionGroup var actions: ActionFlags

    @Option(help: "Also capture afterwards and write the PNG here.")
    var out: String?

    func run() async throws {
        let pending = try actions.actions()
        guard !pending.isEmpty else {
            throw ValidationError("No actions given. See `loupe act --help`.")
        }
        let (results, shot) = try await Loupe.act(
            try target.parsed(), actions: pending, options: target.options(),
            captureAfter: out == nil ? nil : .default)
        for result in results {
            // Scrubbed: a driver reports the value it set, which for an
            // interpolated secret would put it right back on screen.
            print("\(result.ok ? "ok" : "FAILED"): \(Secrets.redact(result.message))")
            if let payload = result.payload, !payload.isEmpty {
                print("  \(Secrets.redact(payload))")
            }
        }
        if let shot, let out {
            let url = try Out.write(shot.png, to: out, fallback: out)
            print(url.path)
        }
    }
}
