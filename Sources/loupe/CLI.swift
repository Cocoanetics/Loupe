import ArgumentParser
import Foundation
import LoupeKit

@main
struct LoupeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "loupe",
        abstract: "Look at and drive UI — web pages, Mac apps, iOS simulators — without taking over the screen.",
        discussion: """
            Targets are uniform across surfaces:

              https://example.com        a page in an offscreen web view
              web:https://example.com    the same, spelled explicitly
              mac:Safari                 an app's frontmost window (name, bundle id, or pid:N)
              mac:Safari#2               that app's window at index 2
              sim:booted                 the booted simulator
              sim:iPhone 17 Pro          a simulator by name or udid
              @checkout                  a live session held open in its own process

            Mac apps and simulators keep their own state, so plain commands can look,
            decide and act in a loop against them. A web page cannot: its web view dies
            with the process. Open a live session to keep one alive across commands:

              loupe session open http://localhost:3000/login --as portal
              loupe act @portal --set 'username=…' --press Login
              loupe describe @portal            # still logged in
              loupe session close portal

            Set a target once and the following commands can omit it:

              loupe use "mac:MyApp#main"
              loupe describe
              loupe set login.username admin
              loupe press login.submit
              loupe wait 'Dashboard|!Invalid password'
              loupe capture --out after.png

            The before/after workflow spans invocations, so the "before" can be
            captured before a fix exists:

              loupe before fix-totals mac:MyApp
              …make the change, rebuild…
              loupe after  fix-totals

            `after` prints the path to a side-by-side proof image with changed
            regions boxed, ready to attach to an issue or MR.
            """,
        subcommands: [
            Capture.self, Describe.self,
            PressCommand.self, SetCommand.self, TypeCommand.self, KeyCommand.self,
            OpenCommand.self, RevealCommand.self, WaitCommand.self, TapCommand.self,
            Act.self, ScriptCommand.self,
            Before.self, After.self, Compare.self, Sessions.self,
            List.self, AtCommand.self, Use.self, Session.self, Window.self, Sim.self, Doctor.self, MCPCommand.self
        ],
        defaultSubcommand: Capture.self)
}

// MARK: - Shared option groups

struct TargetOptions: ParsableArguments {
    @Argument(
        help: "Target to look at. Omit to use the one set by `loupe use` (see `loupe --help`).")
    var target: String?

    @Option(
        name: .customLong("session"),
        help: "Send this command to a live session by name — the same as passing `@name` as the target.")
    var session: String?

    @Option(help: "Web viewport as WxH in CSS pixels.")
    var viewport: String = "1280x900"

    @Option(help: "Web backing scale (2.0 renders Retina-sharp).")
    var scale: Double = 2.0

    @Option(
        help:
            "Named persistent web profile, so cookies and logins survive between runs. Omit for a private session."
    )
    var profile: String?

    /// Precedence: an explicit target, then `--session`, then the remembered one.
    /// Most specific wins, which is what a reader expects when two are present.
    func parsed() throws -> Target {
        if let target { return try Target.parse(target) }
        if let session { return try Target.parse("@\(session)") }
        return try CurrentTarget.resolve(nil)
    }

    /// Falls back to the remembered target's viewport and profile, so a flow does
    /// not silently change page size or lose its login halfway through.
    func options() -> Loupe.Options {
        let current = (target == nil && session == nil) ? CurrentTarget.load() : nil
        return Loupe.Options(
            viewport: Viewport.size(from: viewport == "1280x900" ? (current?.viewport ?? viewport) : viewport),
            scale: scale,
            profile: profile ?? current?.profile)
    }
}

/// The `WxH` viewport spelling, shared by every command that takes one.
enum Viewport {
    /// Falls back to the default rather than throwing: a mistyped viewport should
    /// not stop a capture that has nothing to do with the web.
    static func size(from spec: String) -> CGSize {
        let parts = spec.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return CGSize(width: 1280, height: 900) }
        return CGSize(width: parts[0], height: parts[1])
    }
}

struct CaptureFlags: ParsableArguments {
    @Option(help: "Write the PNG here. Defaults to a file in the current directory.")
    var out: String?

    @Flag(help: "Capture the whole scrollable page (web only).")
    var fullPage = false

    @Flag(
        help: """
            Box and number the actionable elements, with a legend. Read a number off \
            the image, then act on it by number — the handle comes from the \
            accessibility tree, so no coordinate has to be guessed.
            """)
    var annotate = false

    @Flag(
        inversion: .prefixedNo,
        help: """
            Wait for the screen to stop changing first. On by default — animations are \
            the main source of false diffs.
            """)
    var settle = true

    @Option(help: "Seconds to wait for the screen to settle.")
    var settleTimeout: Double = 3.0

    @Option(help: "Crop to a region, as x,y,w,h in target points.")
    var region: String?

    @Option(help: "Downscale so the longest edge is at most this many pixels.")
    var maxEdge: Int?

    func captureOptions() -> CaptureOptions {
        var frame: Frame?
        if let region {
            let numbers = region.split(separator: ",").compactMap {
                Double($0.trimmingCharacters(in: .whitespaces))
            }
            if numbers.count == 4 {
                frame = Frame(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            }
        }
        return CaptureOptions(
            region: frame, fullPage: fullPage, settle: settle, settleTimeout: settleTimeout)
    }

    /// Apply post-processing that is independent of the surface.
    func postProcess(_ data: Data) throws -> Data {
        guard let maxEdge else { return data }
        return try ImageOps.fit(data, maxEdge: maxEdge)
    }
}

/// Actions that run, in order, before the capture — which is what makes
/// "navigate somewhere, do a thing, then show me" a single invocation.
struct ActionFlags: ParsableArguments {
    @Option(
        name: .customLong("step"),
        help: """
            An ordered step, `kind:argument`. Repeatable, and steps run in exactly \
            the order you write them — use this when order matters, which for \
            anything resembling "fill a form then submit it" it does. Kinds: \
            open, launch, set (field=value), press, click (x,y), type, key, \
            scroll (dx,dy), eval, wait (seconds).
            """)
    var step: [String] = []

    @Option(name: .customLong("press"), help: "Activate an element by id, identifier, or label. Repeatable.")
    var press: [String] = []

    @Option(
        name: .customLong("set"),
        help: """
            Set a value: <element>=<text>. Write {{NAME}} to take the value from the \
            environment instead of the command line, so a secret never lands in argv. Repeatable.
            """)
    var set: [String] = []

    @Option(name: .customLong("click"), help: "Click at x,y in target points. Repeatable.")
    var click: [String] = []

    @Option(name: .customLong("type"), help: "Type text into the focused element. Repeatable.")
    var typeText: [String] = []

    @Option(name: .customLong("key"), help: "Press a key: return, tab, escape, up, cmd+s… Repeatable.")
    var key: [String] = []

    @Option(name: .customLong("scroll"), help: "Scroll by dx,dy. Repeatable.")
    var scroll: [String] = []

    @Option(name: .customLong("open"), help: "Open a URL or deep link in the target. Repeatable.")
    var open: [String] = []

    @Option(name: .customLong("launch"), help: "Launch an app (bundle id or .app path) in the target.")
    var launch: [String] = []

    @Option(name: .customLong("eval"), help: "Evaluate JavaScript (web only). Repeatable.")
    var eval: [String] = []

    @Option(name: .customLong("wait"), help: "Wait this many seconds for the screen to settle.")
    var wait: [Double] = []

    func actions() throws -> [UIAction] {
        // Explicit steps win outright, and their order is exactly as written.
        if !step.isEmpty { return try step.map(UIAction.parse(step:)) }

        // Otherwise the convenience flags run in the order a form actually wants:
        // get to the right place, put values in, then activate something. Pressing
        // before setting would submit an empty form — which is exactly the bug this
        // ordering was written to prevent.
        var out: [UIAction] = []
        out += launch.map { .launch($0) }
        out += try open.map { UIAction.navigate(try EnvironmentInterpolation.expand($0)) }
        out += try set.compactMap { pair -> UIAction? in
            guard let equals = pair.firstIndex(of: "=") else { return nil }
            return .setValue(
                node: String(pair[pair.startIndex..<equals]),
                value: try EnvironmentInterpolation.expand(String(pair[pair.index(after: equals)...])))
        }
        out += try typeText.map { UIAction.type(try EnvironmentInterpolation.expand($0)) }
        out += scroll.compactMap { spec in
            guard let delta = Self.pair(spec) else { return nil }
            return .scroll(dx: delta.first, dy: delta.second)
        }
        out += click.compactMap { spec in
            guard let point = Self.pair(spec) else { return nil }
            return .click(x: point.first, y: point.second, space: .windowPoints, viaCursor: false)
        }
        out += press.map { .press(node: $0) }
        out += key.map { .key($0) }
        out += eval.map { .evaluate($0) }
        out += wait.map { .settle(timeout: $0) }
        return out
    }

    /// Two comma-separated numbers, or nil — malformed pairs are skipped rather
    /// than aborting the whole run.
    private static func pair(_ spec: String) -> (first: Double, second: Double)? {
        let numbers = spec.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard numbers.count == 2 else { return nil }
        return (numbers[0], numbers[1])
    }
}

// MARK: - Helpers

enum Out {
    static func write(_ data: Data, to path: String?, fallback: String) throws -> URL {
        let url = URL(fileURLWithPath: path ?? fallback)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func timestampedName(_ prefix: String, ext: String = "png") -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let safe = prefix.replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        return "loupe-\(safe)-\(formatter.string(from: Date())).\(ext)"
    }

    static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LoupeError.failed("encoded JSON was not valid UTF-8")
        }
        return text
    }
}
