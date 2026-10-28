import ArgumentParser
import Foundation
import LoupeKit
import LoupeMCP
import SwiftMCP

/// The CLI's forwarding half of `LOUPE_HOST`: the same verbs, answered by the
/// host that holds the grants, with the results printed exactly as they are
/// when the UI is driven in-process.
///
/// What the host returns is what an agent would get over MCP, so images arrive
/// downscaled and a verb the tool set has no spelling for is refused instead of
/// quietly run locally — a local run is what pointing at a host is meant to stop.
enum HostRoute {

    /// The configured host's client, or nil when running standalone.
    static func client() throws -> LoupeHostClient? {
        try LoupeHost.configured().map { LoupeHostClient(host: $0) }
    }

    static func unsupported(_ what: String) -> LoupeError {
        .failed("\(what) is not available through LOUPE_HOST — unset it to run in this process")
    }

    /// With a host configured, refuse a command that has no forwarding rather than
    /// let it drive the UI here.
    static func check(_ command: ParsableCommand) throws {
        guard let host = try LoupeHost.configured() else { return }
        if LoupeHost.carriesSecrets(CommandLine.arguments), !host.allowsSecrets {
            throw LoupeError.failed(
                "refusing to send {{ENV}} values to \(host.url.absoluteString): expanded secrets "
                    + "may only go to a loopback host or an https:// one")
        }
        switch command {
            case is MCPCommand, is Capture, is Describe, is Act, is List, is Doctor, is any VerbCommand:
                return
            default:
                throw unsupported("`loupe \(type(of: command).configuration.commandName ?? "this command")`")
        }
    }

    // MARK: - Arguments

    static func targetArguments(_ target: Target, _ options: Loupe.Options) -> JSONDictionary {
        var out: JSONDictionary = [
            "target": .string(target.description),
            "viewport": .string("\(Int(options.viewport.width))x\(Int(options.viewport.height))")
        ]
        if let profile = options.profile { out["profile"] = .string(profile) }
        return out
    }

    /// The `loupe_act` argument that says what one step says.
    static func actArguments(_ action: UIAction) throws -> JSONDictionary {
        switch action {
            case .press(let node): return ["press": .string(node)]
            case .setValue(let node, let value): return ["setValue": .string("\(node)=\(value)")]
            case .type(let text): return ["type": .string(text)]
            case .key(let key): return ["key": .string(key)]
            case .scroll(let dx, let dy): return ["scroll": .string("\(dx),\(dy)")]
            case .navigate(let url): return ["open": .string(url)]
            case .launch(let app): return ["launch": .string(app)]
            case .click(let x, let y, let space, let viaCursor):
                return [(viaCursor ? "cursorClick" : "click"): .string("\(spacePrefix(space))\(x),\(y)")]
            default:
                throw unsupported("this step (\(action))")
        }
    }

    private static func spacePrefix(_ space: CoordinateSpace) -> String {
        switch space {
            case .windowPoints: ""
            case .screenPoints: "screen:"
            case .windowPixels: "px:"
            case .normalized: "n:"
        }
    }

    // MARK: - Calls

    /// Run steps one at a time on the host, since a tool call carries one of each
    /// kind. Returns what each said and the last screenshot.
    static func act(
        _ client: LoupeHostClient, target: Target, options: Loupe.Options, actions: [UIAction]
    ) async throws -> (lines: [String], image: Data?) {
        var lines: [String] = []
        var image: Data?
        for action in actions {
            var arguments = targetArguments(target, options)
            for (key, value) in try actArguments(action) { arguments[key] = value }
            let reply = try await client.call("loupe_act", arguments)
            if !reply.text.isEmpty { lines.append(Secrets.redact(reply.text)) }
            image = reply.images.last ?? image
        }
        return (lines, image)
    }
}

extension Capture {
    func runOnHost(_ client: LoupeHostClient) async throws {
        if flags.annotate { throw HostRoute.unsupported("--annotate") }
        let parsed = try target.parsed()
        let options = target.options()
        var image: Data?
        let pending = try actions.actions()
        if !pending.isEmpty {
            image = try await HostRoute.act(client, target: parsed, options: options, actions: pending).image
        }
        let capture = flags.captureOptions()
        var arguments = HostRoute.targetArguments(parsed, options)
        arguments["fullPage"] = .bool(capture.fullPage)
        arguments["settle"] = .bool(capture.settle)
        arguments["scale"] = .double(options.scale)
        if let region = flags.region { arguments["region"] = .string(region) }
        let reply = try await client.call("loupe_capture", arguments)
        guard let shot = reply.images.last ?? image else {
            throw LoupeError.failed("the host returned no image")
        }
        let url = try Out.write(
            try flags.postProcess(shot), to: flags.out, fallback: Out.timestampedName(parsed.locator))
        print(url.path)
    }
}

extension Describe {
    func runOnHost(_ client: LoupeHostClient) async throws {
        var arguments = HostRoute.targetArguments(try target.parsed(), target.options())
        arguments["depth"] = .integer(depth)
        arguments["includeAll"] = .bool(all)
        arguments["menus"] = .bool(menus)
        arguments["actions"] = .bool(actions)
        arguments["format"] = .string(json ? "json" : "outline")
        if let filter { arguments["filter"] = .string(filter) }
        if let at { arguments["at"] = .string(at) }
        print(try await client.call("loupe_describe", arguments).text)
    }
}

extension Act {
    func runOnHost(_ client: LoupeHostClient) async throws {
        let pending = try actions.actions()
        guard !pending.isEmpty else {
            throw ValidationError("No actions given. See `loupe act --help`.")
        }
        let (lines, image) = try await HostRoute.act(
            client, target: try target.parsed(), options: target.options(), actions: pending)
        lines.forEach { print($0) }
        if let image, let out {
            print(try Out.write(image, to: out, fallback: out).path)
        }
    }
}

extension VerbCommand {
    func runVerbOnHost(_ client: LoupeHostClient) async throws {
        let named = targetName ?? sessionName.map { "@\($0)" }
        let target = try CurrentTarget.resolve(named)
        let remembered = named == nil ? CurrentTarget.load() : nil
        let options = Loupe.Options(
            viewport: Viewport.size(from: remembered?.viewport ?? "1280x900"),
            profile: remembered?.profile)
        let (lines, image) = try await HostRoute.act(
            client, target: target, options: options, actions: [try action()])
        lines.forEach { print($0) }
        if let image, let out {
            print(try Out.write(image, to: out, fallback: out).path)
        }
    }
}

extension List {
    func runOnHost(_ client: LoupeHostClient) async throws {
        print(try await client.call("loupe_list_targets").text)
    }
}

extension Doctor {
    func runOnHost(_ client: LoupeHostClient) async throws {
        if request {
            print(try await client.call("loupe_request_access").text)
        }
        print(try await client.call("loupe_doctor").text)
    }
}
