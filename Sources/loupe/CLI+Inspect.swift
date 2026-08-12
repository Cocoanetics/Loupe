import ArgumentParser
import Foundation
import LoupeKit

// MARK: - list

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List targets you can point Loupe at: running apps, their windows, and simulators.")

    @Flag(help: "Emit JSON.")
    var json = false

    func run() async throws {
        let inventory = try await Inventory.collect()
        if json {
            print(try Out.json(inventory))
            return
        }
        print("Mac apps:")
        for app in inventory.apps {
            let windows = app.windows.isEmpty ? "" : "  (\(app.windows.count) window(s))"
            print("  mac:\(app.name)\(windows)   \(app.bundleID ?? "")")
            for (index, title) in app.windows.enumerated() where !title.isEmpty {
                print("    mac:\(app.name)#\(index)  \(title)")
            }
        }
        print("\nSimulators:")
        for device in inventory.simulators {
            let mark = device.state == "Booted" ? "●" : "○"
            print("  \(mark) sim:\(device.name)   \(device.runtime)   \(device.udid)")
        }
        if inventory.simulators.isEmpty { print("  (none available)") }
        print("\nWeb: any URL, e.g. `loupe capture https://example.com`")
    }
}

// MARK: - at

/// The `loupe at` command. Named `AtCommand` because a two-letter type name
/// reads as an abbreviation; the command itself is still spelled `at`.
struct AtCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "at",
        abstract: "Say what element is at a point, without touching it.",
        discussion: """
            For checking your aim before committing. An agent reading a screenshot can
            confirm the point it measured lands on the control it meant, which is a far
            cheaper question than an unintended click.

            The coordinate takes the same spaces as `click`: bare numbers are window
            points, or prefix with `px:`, `n:` or `screen:`.
            """)

    @Argument(help: "Target to inspect.")
    var target: String

    @Argument(help: "Point, e.g. 120,340 or n:0.5,0.33.")
    var point: String

    @Flag(help: "Emit JSON.")
    var json = false

    func run() async throws {
        var space = CoordinateSpace.windowPoints
        var coordinates = point
        if let colon = point.firstIndex(of: ":"),
            let named = CoordinateSpace.parse(String(point[point.startIndex..<colon])) {
            space = named
            coordinates = String(point[point.index(after: colon)...])
        }
        let numbers = coordinates.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard numbers.count == 2 else {
            throw ValidationError("point needs two numbers, e.g. 120,340 or n:0.5,0.33")
        }

        let node = try await Loupe.elementAt(
            try Target.parse(target), x: numbers[0], y: numbers[1], space: space)
        guard let node else {
            print("nothing at that point")
            throw ExitCode(1)
        }
        if json {
            print(try Out.json(node))
        } else {
            printNode(node)
        }
    }

    private func printNode(_ node: UINode) {
        var line = node.role
        if let label = node.label, !label.isEmpty { line += " \"\(label)\"" }
        if let identifier = node.identifier, !identifier.isEmpty { line += " #\(identifier)" }
        if !node.enabled { line += " (disabled)" }
        print(line)
        print("  handle: \(node.id)")
        print("  actions: \(node.actions.isEmpty ? "none" : node.actions.joined(separator: ", "))")
        if let frame = node.frame {
            print(
                String(
                    format: "  frame: x=%.0f y=%.0f w=%.0f h=%.0f", frame.x, frame.y, frame.width,
                    frame.height))
        }
    }
}

// MARK: - doctor

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check the permissions and tools each surface needs.",
        discussion: """
            With --request, asks macOS for whatever is missing instead of only \
            naming it. The system shows each prompt once per binary, so a client \
            that was already answered for — or whose grant a rebuild invalidated \
            — gets no dialog; that is reported, along with where to grant it by \
            hand. Screen Recording reaches a running process only after a restart.
            """)

    @Flag(help: "Ask the system for any missing permission, rather than only reporting it.")
    var request = false

    @Flag(help: "Emit the report as JSON.")
    var json = false

    func run() async throws {
        if request {
            for result in await Diagnostics.requestAccess() {
                print("\(result.grant.rawValue): \(result.note)")
            }
            print("")
        }

        let report = await Diagnostics.run()
        if json {
            let data = try JSONEncoder().encode(report)
            print(String(bytes: data, encoding: .utf8) ?? "")
        } else {
            for line in report.lines { print(line) }
        }
        if !report.allGood {
            if !json { print("\nSome surfaces are unavailable. Fix the items marked ✗ above.") }
            throw ExitCode(1)
        }
    }
}
