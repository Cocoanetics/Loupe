import Foundation
import LoupeCore

/// The host side of the simulator bridge.
///
/// `simctl` has no notion of an element, and the accessibility Simulator.app
/// forwards to macOS is flattened and lossy — a tab bar arrives as a childless
/// group, so the five buttons a script wants are simply not there. The only
/// complete view of a running iOS app is XCUITest's, and XCUITest exists only
/// inside a UI-test process. So Loupe ships one, installs it on the device, and
/// talks to it over loopback.
///
/// Two properties make this cheap enough to be the default rather than a
/// last resort: a UI-test bundle needs no test host, so a single prebuilt
/// runner drives every installed app on every booted device; and it needs no
/// `xcodebuild` at run time, so a session starts in seconds. It also keeps
/// working when the Mac's screen is locked, which neither accessibility route
/// does.
public struct Bridge: Sendable {

    /// Where the built runner and the per-device registry live.
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".loupe/bridge")
    }

    static let bundleID = "com.cocoanetics.loupe.bridge.uitests.xctrunner"

    /// One live bridge, as recorded on disk so separate `loupe` invocations
    /// reuse it rather than each paying the start-up cost.
    struct Descriptor: Codable, Sendable {
        var udid: String
        var port: UInt16
        var token: String
        var startedAt: Date
    }

    let udid: String
    let port: UInt16
    let token: String

    // MARK: - Talking to it

    private func send(
        _ path: String, body: [String: Any] = [:], timeout: TimeInterval = 60
    ) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(token, forHTTPHeaderField: "x-loupe-token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoupeError.failed("bridge returned something that is not JSON")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            throw LoupeError.failed(
                "bridge: \(object["error"] as? String ?? "HTTP \(status)")")
        }
        return object
    }

    func health() async throws -> String {
        let reply = try await send("/health", timeout: 5)
        return reply["bundleID"] as? String ?? ""
    }

    /// Point the bridge at an app. `restart` distinguishes XCUI's `launch()`
    /// from `activate()`: one relaunches, the other attaches to what is already
    /// running, which is what a script inspecting a set-up state wants.
    @discardableResult
    func attach(
        bundleID: String, restart: Bool,
        environment: [String: String] = [:], arguments: [String] = []
    ) async throws -> Bool {
        var body: [String: Any] = ["bundleID": bundleID]
        if !environment.isEmpty { body["environment"] = environment }
        if !arguments.isEmpty { body["arguments"] = arguments }
        let reply = try await send(restart ? "/launch" : "/activate", body: body, timeout: 90)
        return reply["ok"] as? Bool ?? false
    }

    func terminate() async throws {
        _ = try await send("/terminate")
    }

    func describe() async throws -> [UINode] {
        let reply = try await send("/describe", timeout: 90)
        guard let roots = reply["roots"] as? [[String: Any]] else { return [] }
        return roots.compactMap(Self.node(from:))
    }

    /// Send one action and return what the runner said it did.
    @discardableResult
    func perform(kind: String, extra: [String: Any] = [:]) async throws -> String {
        var body: [String: Any] = ["kind": kind]
        body.merge(extra) { _, new in new }
        let reply = try await send("/act", body: body, timeout: 120)
        return reply["message"] as? String ?? "ok"
    }

    func quit() async {
        _ = try? await send("/quit", timeout: 3)
    }

    // MARK: - Decoding

    /// The runner speaks `UINode`'s shape directly, so this is a plain read
    /// rather than a translation — the element-type mapping happens on the
    /// device, where the real XCUI types are.
    private static func node(from raw: [String: Any]) -> UINode? {
        guard let id = raw["id"] as? String, let role = raw["role"] as? String else { return nil }
        var frame: Frame?
        if let box = raw["frame"] as? [String: Double], (box["width"] ?? 0) > 0 {
            frame = Frame(
                x: box["x"] ?? 0, y: box["y"] ?? 0,
                width: box["width"] ?? 0, height: box["height"] ?? 0)
        }
        return UINode(
            id: id,
            role: role,
            rawRole: raw["rawRole"] as? String,
            label: raw["label"] as? String,
            value: raw["value"] as? String,
            identifier: raw["identifier"] as? String,
            frame: frame,
            enabled: raw["enabled"] as? Bool ?? true,
            focused: raw["focused"] as? Bool ?? false,
            actions: raw["actions"] as? [String] ?? [],
            children: (raw["children"] as? [[String: Any]] ?? []).compactMap(node(from:)))
    }
}
