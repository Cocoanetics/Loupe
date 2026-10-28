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
            case is MCPCommand, is Capture, is Describe, is Act, is List, is Doctor, is Record, is any VerbCommand:
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

    /// Run `body` against `target`, held in a temporary host session when it is a
    /// web page and `shared` says several calls must see one page. A web target is
    /// a fresh page load per call, so without this a later step would act on a
    /// reloaded page rather than the one the earlier steps left behind.
    static func scoped<T>(
        _ client: LoupeHostClient, target: Target, options: Loupe.Options, shared: Bool,
        _ body: (Target) async throws -> T
    ) async throws -> T {
        guard shared, target.surface == .web else { return try await body(target) }
        let name = "cli-\(UUID().uuidString.prefix(8).lowercased())"
        var arguments = targetArguments(target, options)
        arguments["name"] = .string(name)
        _ = try await client.call("loupe_session_open", arguments)
        do {
            let result = try await body(try Target.parse("@\(name)"))
            _ = try? await client.call("loupe_session_close", ["name": .string(name)])
            return result
        } catch {
            _ = try? await client.call("loupe_session_close", ["name": .string(name)])
            throw error
        }
    }

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
        let pending = try actions.actions()
        let capture = flags.captureOptions()
        // The capture must see the page the steps left behind, so both share one.
        let reply = try await HostRoute.scoped(
            client, target: parsed, options: options, shared: !pending.isEmpty
        ) { scoped in
            if !pending.isEmpty {
                _ = try await HostRoute.act(client, target: scoped, options: options, actions: pending)
            }
            var arguments = HostRoute.targetArguments(scoped, options)
            arguments["fullPage"] = .bool(capture.fullPage)
            arguments["settle"] = .bool(capture.settle)
            arguments["scale"] = .double(options.scale)
            if let region = flags.region { arguments["region"] = .string(region) }
            return try await client.call("loupe_capture", arguments)
        }
        guard let shot = reply.images.last else {
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
        let parsed = try target.parsed()
        let options = target.options()
        let (lines, image) = try await HostRoute.scoped(
            client, target: parsed, options: options, shared: pending.count > 1
        ) { scoped in
            try await HostRoute.act(client, target: scoped, options: options, actions: pending)
        }
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
        if request, !json {
            print(try await client.call("loupe_request_access").text)
        }
        let text = try await client.call("loupe_doctor").text
        // Same contract as the local command: a surface that is not usable is a
        // failing exit status, not a printed report.
        let (lines, allGood) = LoupeHost.doctorOutput(text, json: json)
        lines.forEach { print($0) }
        if allGood == false {
            if !json { print("\nSome surfaces are unavailable. Fix the items marked ✗ above.") }
            throw ExitCode(1)
        }
    }
}

extension Record {
    /// `loupe_record` on the host. The host films and encodes; the paths it
    /// prints are on the host's disk, which for a loopback host is this one.
    func runOnHost(_ client: LoupeHostClient, target parsed: Target) async throws {
        var arguments = HostRoute.targetArguments(parsed, target.options())
        // As an ordered step list, so `--set … --press …` fills the form before
        // submitting it on the host exactly as it does here.
        let pending = try actions.actions()
        if !pending.isEmpty {
            arguments["steps"] = .array(pending.map { .string($0.step) })
        }
        for (key, value) in hostOptions() { arguments[key] = value }
        let reply = try await client.call("loupe_record", arguments)
        guard let data = reply.text.data(using: .utf8),
            let report = try? JSONDecoder().decode(RecordingReport.self, from: data)
        else {
            print(reply.text)
            return
        }
        if let video = report.videoPath { print(video) }
        if let gif = report.gifPath { print(gif) }
        report.notes.forEach(OutputFlags.note)
    }

    /// The flags that are not steps, as `loupe_record` spells them. Every one
    /// is forwarded, so the host records what this command line asked for.
    private func hostOptions() -> JSONDictionary {
        var out: JSONDictionary = [
            "fps": .double(output.gifFlags.fps), "maxWidth": .integer(output.gifFlags.maxWidth),
            "threshold": .double(output.gifFlags.threshold), "loop": .bool(!output.gifFlags.noLoop),
            "tail": .string(tail), "timeout": .double(timeout), "padding": .double(region.padding)
        ]
        if let duration { out["duration"] = .string(duration) }
        if let until { out["until"] = .string(until) }
        if let frame = region.region { out["region"] = .string(frame) }
        if let element = region.element { out["element"] = .string(element) }
        if let path = output.out { out["out"] = .string(URL(fileURLWithPath: path).path) }
        if output.gif { out["gif"] = .bool(true) }
        if output.appstore { out["appStore"] = .bool(true) }
        if let family = output.appstoreDevice { out["appStoreDevice"] = .string(family.rawValue) }
        return out
    }
}
