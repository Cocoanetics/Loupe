import ArgumentParser
import Foundation
import LoupeKit

struct Session: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "Keep a target open across commands, so you can look, decide and act in a loop.",
        discussion: """
            Only web targets really need this — a Mac app or a simulator already
            outlives your commands, so `loupe act mac:Safari` then `loupe describe
            mac:Safari` works with no session at all. A web page has no such owner:
            without a session every command reloads it and any login, scroll position
            or form state is gone.

            A session is one helper process, not a system daemon. It exits on its own
            after 15 idle minutes, and `loupe session list` forgets any whose process
            has died.
            """,
        subcommands: [Open.self, ListSessions.self, Close.self, Serve.self])

    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "open", abstract: "Open a target and keep it alive.")

        @Argument(help: "Target to hold open.")
        var target: String

        @Option(name: .customLong("as"), help: "Name to address it by, as @name.")
        var name: String

        @Option(help: "Web viewport as WxH.") var viewport: String = "1280x900"
        @Option(help: "Web backing scale.") var scale: Double = 2.0
        @Option(help: "Named persistent web profile.") var profile: String?
        @Option(help: "Exit after this many idle seconds. 0 disables.")
        var idleTimeout: Double = 900

        @Flag(
            inversion: .prefixedNo,
            help: """
                Also remember it, so later commands can omit the target. On by default \
                — opening a session and then not using it is almost never what you meant.
                """)
        var use = true

        func run() async throws {
            try await SessionLauncher.open(
                SessionLauncher.Request(
                    target: try Target.parse(target), name: name, viewport: viewport, scale: scale,
                    profile: profile, idleTimeout: idleTimeout, remember: use))
        }
    }

    struct ListSessions: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: "List open sessions.")

        func run() async throws {
            let sessions = LiveSession.list()
            guard !sessions.isEmpty else {
                print("No open sessions. Start one with `loupe session open <target> --as <name>`.")
                return
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            for session in sessions {
                let since = formatter.string(from: session.startedAt)
                print("@\(session.name)  \(session.target)  pid \(session.pid)  since \(since)")
            }
        }
    }

    struct Close: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "close", abstract: "Close a session.")

        @Argument(help: "Session name, with or without the @.")
        var name: String

        func run() async throws {
            let clean = name.hasPrefix("@") ? String(name.dropFirst()) : name
            let descriptor = try LiveSession.load(clean)
            // Ask nicely first so the driver can shut its web view down cleanly.
            let driver = try LiveSessionDriver(name: clean)
            _ = try? await driver.perform(.settle(timeout: 0))
            kill(descriptor.pid, SIGTERM)
            LiveSession.remove(clean)
            print("closed @\(clean)")
        }
    }

    /// The session's own process. Not meant to be run by hand.
    struct Serve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "serve", abstract: "Internal: run a session's process.",
            shouldDisplay: false)

        @Argument var target: String
        @Option(name: .customLong("as")) var name: String
        @Option var viewport: String = "1280x900"
        @Option var scale: Double = 2.0
        @Option var profile: String?
        @Option var idleTimeout: Double = 900

        func run() async throws {
            let size = Viewport.size(from: viewport)
            let server = LiveSessionServer(
                name: name,
                target: try Target.parse(target),
                options: Loupe.Options(viewport: size, scale: scale, profile: profile),
                idleTimeout: idleTimeout)
            try await server.run()
        }
    }
}
