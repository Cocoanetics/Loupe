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
            """)

    @Argument(help: "Command: close, minimize, deminimize or raise.")
    var command: String

    @Argument(help: "A mac: target, e.g. mac:Safari#1.")
    var target: String

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
        let driver = MacDriver(
            appLocator: parsed.locator, windowIndex: parsed.windowIndex,
            windowTitle: parsed.windowTitle)
        print(try await driver.window(verb).message)
    }
}
