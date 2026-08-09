import ArgumentParser
import Foundation
import LoupeKit

/// One action as its own command, e.g. `loupe press Save`.
///
/// `act --step 'press:Save'` says the same thing, but encodes the verb, its
/// argument and sometimes a coordinate space into one shell word — a small
/// language living inside `argv`, with its own quoting and nested delimiters
/// (`click:n:0.5,0.5`, `set:field=value`, `await:A|!B@25`). That is the right
/// shape for an ordered batch and the wrong shape for a single step.
///
/// These verbs take their arguments as arguments, and default to the target
/// remembered by `loupe use`, so an incremental flow reads as a sequence of
/// plain commands.
protocol VerbCommand: AsyncParsableCommand {
    var targetName: String? { get }
    /// A live session to send this to, equivalent to `@name` as the target.
    var sessionName: String? { get }
    func action() throws -> UIAction
    /// Screenshot after acting and write it here.
    var out: String? { get }
}

extension VerbCommand {
    func runVerb() async throws {
        // Most specific wins: an explicit target, then --session, then whatever
        // `loupe use` remembered.
        let named = targetName ?? sessionName.map { "@\($0)" }
        let target = try CurrentTarget.resolve(named)
        let remembered = named == nil ? CurrentTarget.load() : nil
        let options = Loupe.Options(
            viewport: Viewport.size(from: remembered?.viewport ?? "1280x900"),
            profile: remembered?.profile)

        let (results, shot) = try await Loupe.act(
            target, actions: [try action()], options: options,
            captureAfter: out == nil ? nil : .default)
        for result in results {
            // Scrubbed: drivers report the value they set, which for an
            // interpolated secret would put it straight back on screen.
            print("\(result.ok ? "ok" : "FAILED"): \(Secrets.redact(result.message))")
            if let payload = result.payload, !payload.isEmpty {
                print("  \(Secrets.redact(payload))")
            }
        }
        if let shot, let out {
            print(try Out.write(shot.png, to: out, fallback: out).path)
        }
    }
}

// MARK: - Verbs

struct PressCommand: VerbCommand {
    static let configuration = CommandConfiguration(
        commandName: "press",
        abstract: "Activate an element by handle, identifier or label.")

    @Argument(help: "Element to activate.") var element: String
    @Option(name: .customLong("target"), help: "Target, if not the remembered one.")
    var targetName: String?
    @Option(name: .customLong("session"), help: "Live session to send this to, by name.")
    var sessionName: String?
    @Option(help: "Capture afterwards and write the PNG here.") var out: String?

    func action() throws -> UIAction { .press(node: element) }
    func run() async throws { try await runVerb() }
}

struct SetCommand: VerbCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set an element's value directly, without keystrokes.",
        discussion: """
            Write {{NAME}} as the value to read it from the environment instead of \
            the command line, so a secret never lands in argv. Secure text fields \
            refuse this — macOS will not let accessibility set them — so type into \
            those instead.
            """)

    @Argument(help: "Element to set.") var element: String
    @Argument(help: "Value, or {{ENV_VAR}}.") var value: String
    @Option(name: .customLong("target"), help: "Target, if not the remembered one.")
    var targetName: String?
    @Option(name: .customLong("session"), help: "Live session to send this to, by name.")
    var sessionName: String?
    @Option(help: "Capture afterwards and write the PNG here.") var out: String?

    func action() throws -> UIAction {
        .setValue(node: element, value: try EnvironmentInterpolation.expand(value))
    }
    func run() async throws { try await runVerb() }
}

struct TypeCommand: VerbCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text into whatever has focus.")

    @Argument(help: "Text, or {{ENV_VAR}}.") var text: String
    @Option(name: .customLong("target"), help: "Target, if not the remembered one.")
    var targetName: String?
    @Option(name: .customLong("session"), help: "Live session to send this to, by name.")
    var sessionName: String?
    @Option(help: "Capture afterwards and write the PNG here.") var out: String?

    func action() throws -> UIAction { .type(try EnvironmentInterpolation.expand(text)) }
    func run() async throws { try await runVerb() }
}

struct KeyCommand: VerbCommand {
    static let configuration = CommandConfiguration(
        commandName: "key",
        abstract: "Press a key: return, tab, escape, up, cmd+s…")

    @Argument(help: "Key or combination.") var key: String
    @Option(name: .customLong("target"), help: "Target, if not the remembered one.")
    var targetName: String?
    @Option(name: .customLong("session"), help: "Live session to send this to, by name.")
    var sessionName: String?
    @Option(help: "Capture afterwards and write the PNG here.") var out: String?

    func action() throws -> UIAction { .key(key) }
    func run() async throws { try await runVerb() }
}

struct OpenCommand: VerbCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open a URL or deep link in the target.")

    @Argument(help: "URL or deep link.") var url: String
    @Option(name: .customLong("target"), help: "Target, if not the remembered one.")
    var targetName: String?
    @Option(name: .customLong("session"), help: "Live session to send this to, by name.")
    var sessionName: String?
    @Option(help: "Capture afterwards and write the PNG here.") var out: String?

    func action() throws -> UIAction { .navigate(try EnvironmentInterpolation.expand(url)) }
    func run() async throws { try await runVerb() }
}

struct RevealCommand: VerbCommand {
    static let configuration = CommandConfiguration(
        commandName: "reveal",
        abstract: "Scroll an element into view.",
        discussion: """
            Asks the app to reveal the element — AXScrollToVisible on macOS, \
            scrollIntoView on the web — rather than guessing a scroll distance, \
            which also does the right thing inside nested scrollers.
            """)

    @Argument(help: "Element to bring into view.") var element: String
    @Option(name: .customLong("target"), help: "Target, if not the remembered one.")
    var targetName: String?
    @Option(name: .customLong("session"), help: "Live session to send this to, by name.")
    var sessionName: String?
    @Option(help: "Capture afterwards and write the PNG here.") var out: String?

    func action() throws -> UIAction { .scrollTo(node: element) }
    func run() async throws { try await runVerb() }
}

struct WaitCommand: VerbCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Wait for an element to appear and be usable.",
        discussion: """
            Give several alternatives separated by `|` to return as soon as any of \
            them shows up, and prefix one with `!` to make it a failure. That is what \
            makes waiting usable after a login: racing the expected screen against \
            the app's own error returns in the time the app takes to reject you, \
            instead of burning the whole timeout and then reporting nothing useful.

              loupe wait 'Health Dashboard|!Invalid password'
            """)

    @Argument(help: "What to wait for. `A|B` for either, `!X` for a failure condition.")
    var expected: String
    @Option(help: "Seconds to wait.") var timeout: Double = 10
    @Flag(help: "Wait for it to disappear instead.") var gone = false
    @Option(name: .customLong("target"), help: "Target, if not the remembered one.")
    var targetName: String?
    @Option(name: .customLong("session"), help: "Live session to send this to, by name.")
    var sessionName: String?
    @Option(help: "Capture afterwards and write the PNG here.") var out: String?

    func action() throws -> UIAction {
        var nodes: [String] = []
        var failures: [String] = []
        for candidate in expected.split(separator: "|") {
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("!") {
                failures.append(String(trimmed.dropFirst()))
            } else {
                nodes.append(trimmed)
            }
        }
        return .waitFor(nodes: nodes, failIf: failures, gone: gone, timeout: timeout)
    }
    func run() async throws { try await runVerb() }
}

struct TapCommand: VerbCommand {
    static let configuration = CommandConfiguration(
        commandName: "tap",
        abstract: "Click at a point, through accessibility.",
        discussion: """
            Hit-tests the point and presses whatever is there, so it needs no label — \
            only that something at that point is actionable. Nothing moves on screen.

            The coordinate space is explicit because there are four plausible answers \
            and picking wrong lands the click somewhere else: bare numbers are window \
            points, `px:` capture pixels, `n:` a fraction of the window, `screen:` \
            global. Use `n:` when working from a screenshot whose size you are not \
            certain of — including any image delivered over MCP, which is downscaled.
            """)

    @Argument(help: "Point, e.g. 120,340 or n:0.5,0.33.") var point: String
    @Flag(help: "Use a real mouse click. Visible to the user; needs the window unobscured.")
    var cursor = false
    @Option(name: .customLong("target"), help: "Target, if not the remembered one.")
    var targetName: String?
    @Option(name: .customLong("session"), help: "Live session to send this to, by name.")
    var sessionName: String?
    @Option(help: "Capture afterwards and write the PNG here.") var out: String?

    func action() throws -> UIAction {
        try UIAction.parse(step: "\(cursor ? "cursorclick" : "click"):\(point)")
    }
    func run() async throws { try await runVerb() }
}
