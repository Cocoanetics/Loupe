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

    @Option(help: "Give up after this many seconds. Unlimited by default.")
    var timeout: Double?

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
        let request = ScriptRequest(
            source: source,
            fileName: name,
            defaultTarget: target,
            options: Loupe.Options(
                // An explicit --viewport wins over the remembered one; the
                // other way round silently ignores what was just asked for.
                viewport: Viewport.size(from: explicitViewport ?? remembered?.viewport ?? viewport),
                profile: profile ?? remembered?.profile),
            attachmentDirectory: screenshots.map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
            })

        // The same call the MCP tool makes. `echo` is the only difference: at a
        // terminal a script's prints should appear as they happen rather than
        // arriving in a heap once the flow is over.
        let report = await LoupeScript.run(request, timeout: timeout) { text in
            FileHandle.standardOutput.write(Data(text.utf8))
        }

        for path in report.attachments {
            FileHandle.standardError.write(Data("screenshot: \(path)\n".utf8))
        }
        FileHandle.standardError.write(Data(report.text.utf8))
        if !report.isSuccess { throw ExitCode.failure }
    }
}
