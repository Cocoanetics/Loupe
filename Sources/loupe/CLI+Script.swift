import ArgumentParser
import Foundation
import LoupeKit
import LoupeXCUI

/// `loupe script flow.swift` — run a UI-test-shaped script.
struct ScriptCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "script",
        abstract: "Run a UI flow written in the XCUITest API.",
        discussion: """
            The script is ordinary Swift written against `XCUIApplication`, and it \
            is the same source a UI test would contain — `import XCUIAutomation` \
            resolves to Apple's framework when the file is compiled into a test \
            target, and to Loupe's drivers when it is run here.

              import XCUIAutomation

              let app = XCUIApplication(target: "web:https://example.com")
              app.launch()
              app.textFields["username"].typeText("admin")
              app.secureTextFields["password"].typeText(env("APP_PASSWORD"))
              app.buttons["Sign In"].tap()
              XCTAssertTrue(app.staticTexts["Dashboard"].waitForExistence(timeout: 10))

            Unlike a test, it drives whatever is already running: no test bundle, \
            no runner, and the app never comes forward. Run `loupe script \
            --divergences` for the full list of where this surface departs from \
            Apple's.
            """)

    @Argument(help: "Script file to run. Use `-` to read from stdin.")
    var path: String?

    @Option(
        name: .customLong("target"),
        help: "What a bare XCUIApplication() refers to, e.g. mac:MyApp or @session.")
    var targetName: String?

    @Option(help: "Web viewport as WxH in CSS pixels.")
    var viewport: String = "1280x900"

    /// Whether `--viewport` was actually written, as opposed to defaulted.
    private var explicitViewport: String? {
        CommandLine.arguments.contains("--viewport") ? viewport : nil
    }

    @Option(help: "Named persistent web profile, so a login survives between runs.")
    var profile: String?

    @Option(help: "Directory for screenshots the script attaches.")
    var screenshots: String?

    @Flag(help: "List where this surface differs from Apple's XCUITest, and exit.")
    var divergences = false

    func run() async throws {
        if divergences {
            print("Loupe's XCUITest surface differs from Apple's in these ways:\n")
            for line in XCUIModule.divergences { print("  • \(line)") }
            return
        }
        guard let path else {
            throw ValidationError("no script given — pass a file, or `-` to read stdin")
        }

        let source: String
        let name: String
        if path == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            // Refusing beats decoding to "" — an empty script "passes",
            // so a CI step piping in UTF-16 would go green having run nothing.
            guard let decoded = String(bytes: data, encoding: .utf8) else {
                throw ValidationError("the script on stdin is not valid UTF-8")
            }
            source = decoded
            name = "<stdin>"
        } else {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            source = try String(contentsOf: url, encoding: .utf8)
            name = url.lastPathComponent
        }

        // An explicit --target wins; otherwise fall back to whatever `loupe use`
        // remembered, so a script slots into a flow already in progress.
        let target = try? CurrentTarget.resolve(targetName)
        let remembered = targetName == nil ? CurrentTarget.load() : nil
        let runner = ScriptRunner(
            options: Loupe.Options(
                // An explicit --viewport wins over the remembered one; the
                // other way round silently ignores what was just asked for.
                viewport: Viewport.size(from: explicitViewport ?? remembered?.viewport ?? viewport),
                profile: profile ?? remembered?.profile),
            defaultTarget: target,
            attachmentDirectory: screenshots.map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
            })

        let outcome = await runner.run(source: source, fileName: name)
        try report(outcome, name: name)
    }

    /// Print what happened, and set the exit status from it.
    private func report(_ outcome: ScriptRunner.Outcome, name: String) throws {
        for url in outcome.attachments {
            FileHandle.standardError.write(Data("screenshot: \(url.path)\n".utf8))
        }
        let seconds = String(format: "%.1fs", outcome.duration)
        switch outcome.result {
            case .passed:
                FileHandle.standardError.write(Data("\(name) passed in \(seconds)\n".utf8))
            case .skipped(let reason):
                FileHandle.standardError.write(
                    Data("\(name) skipped after \(seconds)\(reason.isEmpty ? "" : ": \(reason)")\n".utf8))
            case .failed(let message):
                // List every recorded expectation rather than only the summary.
                // Reporting them together is the entire point of letting a
                // failed expectation continue.
                var report = "\(name) FAILED after \(seconds)\n"
                if outcome.issues.isEmpty {
                    report += "\(message)\n"
                } else {
                    for issue in outcome.issues {
                        // An issue may be a whole rendered source listing, so the
                        // bullet marks its first line and the rest indents under it.
                        let lines = issue.split(separator: "\n", omittingEmptySubsequences: false)
                        report += "  ✗ \(lines.first ?? "")\n"
                        for line in lines.dropFirst() where !line.isEmpty {
                            report += "    \(line)\n"
                        }
                    }
                }
                FileHandle.standardError.write(Data(report.utf8))
                throw ExitCode.failure
        }
    }
}
