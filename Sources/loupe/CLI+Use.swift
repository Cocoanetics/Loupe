import ArgumentParser
import Foundation
import LoupeKit

/// `loupe use` — remember a target so the following commands do not repeat it.
struct Use: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "use",
        abstract: "Remember a target, so later commands can omit it.",
        discussion: """
            Driving a UI is a flow — look, decide, act, look again — but each CLI \
            command is its own process, so without this every step repeats the same \
            quoted target and the noise buries the part that actually changed:

              loupe use "mac:My App#main"
              loupe describe
              loupe set admin.login.username admin
              loupe press admin.login.submit
              loupe capture --out after.png

            The choice is remembered on disk, so it survives across shells and across \
            an agent running each step as a separate command. Any command can still \
            name its own target, which wins for that one call.

            `loupe use --clear` forgets it; `loupe use` with no argument prints it.
            """)

    @Argument(help: "Target to remember. Omit to print the current one.")
    var target: String?

    @Option(help: "Web viewport as WxH, remembered with the target.")
    var viewport: String?

    @Option(help: "Named persistent web profile, remembered with the target.")
    var profile: String?

    @Flag(
        name: .customLong("session"),
        help: """
            Hold the target open in its own process first, then remember that. Worth it \
            when a flow has many steps, and required for web targets, whose state dies \
            with each command.
            """)
    var asSession = false

    @Option(name: .customLong("as"), help: "Name for the session, when opening one.")
    var sessionAlias: String?

    @Flag(help: "Forget the remembered target.")
    var clear = false

    func run() async throws {
        if clear {
            CurrentTarget.clear()
            print("forgot the remembered target")
            return
        }

        guard let target else {
            guard let current = CurrentTarget.load() else {
                print("no target remembered — set one with `loupe use <target>`")
                throw ExitCode(1)
            }
            var line = current.target
            if let viewport = current.viewport { line += "  viewport \(viewport)" }
            if let profile = current.profile { line += "  profile \(profile)" }
            print(line)
            return
        }

        // Parse before saving: remembering something unusable would fail later, at
        // a point where the cause is much less obvious.
        let parsed = try Target.parse(target)

        guard asSession else {
            try CurrentTarget.save(
                CurrentTarget(target: parsed.description, viewport: viewport, profile: profile))
            print(parsed.description)
            return
        }

        guard parsed.surface != .live else {
            throw ValidationError("\(parsed.description) is already a session")
        }
        // Name it after the target so `loupe session list` stays readable, and so
        // running `use --session` twice on the same target is idempotent.
        let name = sessionAlias ?? LiveSession.suggestedName(for: parsed)
        if (try? LiveSession.load(name)) == nil {
            try await SessionLauncher.open(
                SessionLauncher.Request(
                    target: parsed, name: name, viewport: viewport ?? "1280x900", profile: profile))
        } else {
            try CurrentTarget.save(
                CurrentTarget(target: "@\(name)", viewport: viewport, profile: profile))
            print("@\(name)")
        }
    }
}
