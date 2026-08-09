import ArgumentParser
import Foundation
import LoupeKit

// MARK: - before / after / compare

struct Before: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "before",
        abstract: "Capture the 'before' side of a named comparison.")

    @Argument(help: "Session name, e.g. the issue number.")
    var session: String

    @OptionGroup var target: TargetOptions
    @OptionGroup var flags: CaptureFlags
    @OptionGroup var actions: ActionFlags

    func run() async throws {
        let (shot, path) = try await Loupe.before(
            session: session,
            target: try target.parsed(),
            options: target.options(),
            capture: flags.captureOptions(),
            actions: try actions.actions())
        print(path.path)
        FileHandle.standardError.write(
            Data("recorded 'before' for session '\(session)' — \(shot.target)\n".utf8))
    }
}

struct After: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "after",
        abstract: "Capture the 'after' side and build the side-by-side proof image.")

    @Argument(help: "Session name used for `loupe before`.")
    var session: String

    @Argument(help: "Target. Omit to reuse the one recorded with `before`.")
    var target: String?

    @Option(help: "Web viewport as WxH in CSS pixels.")
    var viewport: String = "1280x900"

    @Option(help: "Web backing scale.")
    var scale: Double = 2.0

    @Option(help: "Named persistent web profile.")
    var profile: String?

    @OptionGroup var flags: CaptureFlags
    @OptionGroup var actions: ActionFlags

    func run() async throws {
        let size = Viewport.size(from: viewport)
        let outcome = try await Loupe.after(
            session: session,
            target: try target.map { try Target.parse($0) },
            options: Loupe.Options(viewport: size, scale: scale, profile: profile),
            capture: flags.captureOptions(),
            actions: try actions.actions())
        print(outcome.path.path)
        FileHandle.standardError.write(Data("\(outcome.report.summary)\n".utf8))
        if !outcome.report.isDifferent {
            FileHandle.standardError.write(
                Data("warning: nothing changed — is this really the fixed state?\n".utf8))
        }
    }
}

struct Compare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Compare two PNG files directly, without a session.")

    @Argument var before: String
    @Argument var after: String

    @Option(help: "Write the side-by-side image here.")
    var out: String?

    @Option(help: "Per-channel tolerance below which pixels count as equal.")
    var tolerance: Int = ImageOps.defaultTolerance

    @Flag(help: "Emit the diff report as JSON.")
    var json = false

    func run() async throws {
        let beforeImage = try Data(contentsOf: URL(fileURLWithPath: before))
        let afterImage = try Data(contentsOf: URL(fileURLWithPath: after))
        let report = try ImageOps.diff(before: beforeImage, after: afterImage, tolerance: tolerance)
        let composite = try ImageOps.sideBySide(
            before: beforeImage, after: afterImage, report: report, caption: report.summary)
        let url = try Out.write(composite, to: out, fallback: Out.timestampedName("compare"))
        if json {
            print(try Out.json(report))
        } else {
            print(url.path)
            FileHandle.standardError.write(Data("\(report.summary)\n".utf8))
        }
    }
}

struct Sessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sessions", abstract: "List recorded before/after sessions.")

    func run() async throws {
        let store = ComparisonStore()
        let all = try store.list()
        guard !all.isEmpty else {
            print("No sessions yet. Start one with `loupe before <name> <target>`.")
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for session in all {
            let state = session.afterAt == nil ? "before only" : "complete"
            let when = session.afterAt ?? session.beforeAt
            let stamp = when.map(formatter.string(from:)) ?? ""
            print("\(session.name)  [\(state)]  \(session.target)  \(stamp)")
        }
    }
}
