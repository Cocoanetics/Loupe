import ArgumentParser
import Foundation
import LoupeKit
import LoupeMac

struct Window: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window",
        abstract: "Close, minimize or raise a Mac app's window.",
        discussion: """
            All four are plain accessibility actions on the window's own controls,
            so none of them activates the app or needs Apple Events. That matters:
            Automation consent is per-application and blocks on a user prompt, which
            makes AppleScript unusable for anything running unattended.

            `raise` reorders a window to the front of its app without activating the
            app, so the user's frontmost application does not change.

            `close` can work through many windows at once. `--title` selects by title
            (a glob such as 'CRATEFLOW*', or a plain substring), `--all` closes every
            match instead of refusing when there is more than one, and `--answer`
            presses the named button when closing puts up a sheet or alert — e.g.
            `--answer "Don't Save"`; straight and curly apostrophes match. Each window
            is reported as closed, answered or left open, and any left open makes the
            exit status 1. `--dry-run` lists what would be closed.

              loupe window close mac:Mail --title 'CRATEFLOW*' --all --answer "Don't Save"
            """)

    @Argument(help: "Command: close, minimize, deminimize or raise.")
    var command: String

    @Argument(help: "A mac: target, e.g. mac:Safari#1.")
    var target: String

    @Option(
        help: ArgumentHelp(
            "close: only windows whose title matches — a glob like 'Draft*', or a substring.",
            valueName: "pattern"))
    var title: String?

    @Flag(help: "close: close every matching window, not just one.")
    var all = false

    @Option(
        help: ArgumentHelp(
            "close: press this button if closing shows a sheet or alert, e.g. \"Don't Save\".",
            valueName: "button"))
    var answer: String?

    @Flag(help: "close: list the windows that would be closed, and close none.")
    var dryRun = false

    private var closesInBulk: Bool { title != nil || all || answer != nil || dryRun }

    func run() async throws {
        let parsed = try Target.parse(target)
        guard parsed.surface == .mac else {
            throw ValidationError("window commands only apply to mac: targets")
        }
        guard let verb = MacDriver.WindowCommand(rawValue: command.lowercased()) else {
            throw ValidationError(
                "unknown window command '\(command)' — use "
                    + MacDriver.WindowCommand.allCases.map(\.rawValue).joined(separator: ", "))
        }
        if closesInBulk, verb != .close {
            throw ValidationError("--title, --all, --answer and --dry-run only apply to close")
        }
        let driver = MacDriver(
            appLocator: parsed.locator, windowIndex: parsed.windowIndex,
            windowTitle: parsed.windowTitle, windowID: parsed.windowID)
        guard closesInBulk else {
            print(try await driver.window(verb).message)
            return
        }
        let outcomes = try await driver.closeWindows(
            MacDriver.CloseRequest(
                title: title.map(TitlePattern.init), all: all, answer: answer, dryRun: dryRun))
        outcomes.forEach { print($0.message) }
        if outcomes.contains(where: { $0.status == WindowCloseStatus.leftOpen }) { throw ExitCode(1) }
    }
}
