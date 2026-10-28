import Foundation
import Logging
import LoupeKit
import SwiftMCP

/// A host that holds Loupe's grants and drives the UI on the CLI's behalf.
///
/// Set `LOUPE_HOST` to the host's MCP URL and `loupe <verb>` and `loupe mcp`
/// forward there instead of driving the UI in this process. Unset, nothing
/// changes. Only HTTP(S) endpoints are understood; anything else is rejected
/// rather than silently ignored, because a typo would otherwise fall back to
/// driving the UI locally, which is exactly what the variable is set to avoid.
public struct LoupeHost: Sendable {
    public let url: URL
    /// What the host put in front of Loupe's tool names (`LOUPE_HOST_PREFIX`).
    public let toolPrefix: String

    public init(url: URL, toolPrefix: String = "") {
        self.url = url
        self.toolPrefix = toolPrefix
    }

    /// The host named by the environment, `nil` when running standalone.
    public static func configured(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> LoupeHost? {
        guard let raw = environment["LOUPE_HOST"]?.trimmingCharacters(in: .whitespaces),
            !raw.isEmpty
        else { return nil }
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased()),
            url.host != nil
        else {
            throw LoupeError.failed(
                "LOUPE_HOST must be the host's MCP URL (http:// or https://), got '\(raw)'")
        }
        return LoupeHost(url: url, toolPrefix: environment["LOUPE_HOST_PREFIX"] ?? "")
    }
}

/// What a forwarded tool call came back with.
public struct LoupeHostReply: Sendable {
    public let text: String
    public let images: [Data]
}

/// A connection to a ``LoupeHost``.
public actor LoupeHostClient {
    private let host: LoupeHost
    private let proxy: MCPServerProxy
    private var connected = false

    public init(host: LoupeHost) {
        self.host = host
        self.proxy = MCPServerProxy(config: .sse(config: MCPServerSseConfig(url: host.url)))
    }

    private func ensureConnected() async throws {
        guard !connected else { return }
        try await proxy.connect(clientName: "loupe", clientVersion: "0.1.0")
        connected = true
    }

    /// Send a JSON-RPC request through untouched, which is how `loupe mcp` relays.
    func forward(_ message: JSONRPCMessage) async throws -> JSONRPCMessage {
        try await ensureConnected()
        return try await proxy.send(message)
    }

    /// Call one of Loupe's tools on the host by its bare `loupe_*` name.
    public func call(_ tool: String, _ arguments: JSONDictionary = [:]) async throws -> LoupeHostReply {
        let request = JSONRPCMessage.request(
            id: .string(UUID().uuidString), method: "tools/call",
            params: .object([
                "name": .string(host.toolPrefix + tool), "arguments": .object(arguments),
            ]))
        let response = try await forward(request)
        let result: JSONDictionary
        switch response {
            case .response(let data):
                guard let dictionary = data.result?.dictionaryValue else {
                    throw LoupeError.failed("host sent an unreadable answer to \(tool)")
                }
                result = dictionary
            case .errorResponse(let failure):
                throw LoupeError.failed("host refused \(tool): \(failure.error.message)")
            default:
                throw LoupeError.failed("host sent an unexpected answer to \(tool)")
        }
        var text: [String] = []
        var images: [Data] = []
        for block in result["content"]?.arrayValue ?? [] {
            guard let item = block.dictionaryValue else { continue }
            switch item["type"]?.stringValue {
                case "text":
                    if let value = item["text"]?.stringValue { text.append(value) }
                case "image":
                    if let value = item["data"]?.stringValue, let data = Data(base64Encoded: value) {
                        images.append(data)
                    }
                default: break
            }
        }
        let joined = text.joined(separator: "\n")
        if result["isError"]?.boolValue == true {
            throw LoupeError.failed(joined.isEmpty ? "\(tool) failed on the host" : joined)
        }
        return LoupeHostReply(text: joined, images: images)
    }

    public func disconnect() async {
        if connected { await proxy.disconnect() }
        connected = false
    }
}

/// `loupe mcp` with a host: this process serves stdio and passes the tool
/// traffic to the host, so an agent's client sees the host's tools unchanged.
public final class LoupeRelayServer: MCPServer, Sendable {
    private let client: LoupeHostClient

    public init(host: LoupeHost) {
        self.client = LoupeHostClient(host: host)
    }

    public func handleMessage(_ message: JSONRPCMessage) async -> JSONRPCMessage? {
        guard case .request(let request) = message else { return nil }
        switch request.method {
            case "initialize":
                let asked = request.params?.dictionaryValue?["protocolVersion"]?.stringValue
                return .response(
                    id: request.id,
                    result: [
                        "protocolVersion": .string(asked ?? "2025-06-18"),
                        "capabilities": ["tools": [:]],
                        "serverInfo": ["name": "loupe", "version": "0.1.0"],
                    ])
            case "ping":
                return .response(id: request.id, result: [:])
            case "tools/list", "tools/call":
                do {
                    return try await client.forward(message)
                } catch {
                    return .errorResponse(
                        id: request.id,
                        error: .init(code: -32603, message: "host unreachable: \(error.localizedDescription)"))
                }
            default:
                return .errorResponse(
                    id: request.id, error: .init(code: -32601, message: "Method not found: \(request.method)"))
        }
    }

    public func handleRootsListChanged() async {}

    public func shutdown() async { await client.disconnect() }

    public static func serveOverStdio(host: LoupeHost) async throws {
        var logger = Logger(label: "dev.cocoanetics.loupe.mcp")
        logger.logLevel = .warning
        try await LoupeRelayServer(host: host).serve(over: [StdioTransport()], logger: logger)
    }
}
