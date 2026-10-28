import Foundation
import LoupeKit
import SwiftMCP

/// One Loupe tool, in the pieces a host needs to register it on its own server.
public struct LoupeTool: Sendable {

    /// Name, description and parameter schema — already carrying the host's prefix.
    public let metadata: MCPToolMetadata

    /// Runs the tool. Arguments are the call's JSON arguments, as received.
    public let handler: @Sendable (JSONDictionary) async throws -> any Encodable & Sendable

    public var name: String { metadata.name }
}

/// Loupe's `loupe_*` tool set, for a host to mount on a server of its own.
///
/// `loupe mcp` is one such host (`LoupeMCPServer`). A daemon that wants Loupe's
/// tools inside its own run-scoped server builds a `LoupeTools` instead, and
/// registers either each ``LoupeTool`` or the whole value, which is itself an
/// `MCPToolProviding`:
///
///     let loupe = LoupeTools(prefix: "ui_", allow: ["loupe_capture", "loupe_describe"])
///     try await context.perform { try await loupe.callTool("ui_loupe_capture", arguments: args) }
///
/// One instance keeps what the tools remember between calls (the last comparison
/// per session), so share it across the calls that belong together.
public final class LoupeTools: MCPToolProviding, Sendable {

    private let engine: LoupeMCPServer
    private let prefix: String
    private let allowed: Set<String>?

    /// - Parameters:
    ///   - prefix: Put in front of every tool name, to keep them apart from the
    ///     host's own.
    ///   - allow: Tools to offer, by their `loupe_*` name (the prefixed spelling
    ///     is accepted too). `nil` offers all; the read-only ones are what a
    ///     read-only role wants.
    ///   - maxEdge: Longest edge, in pixels, of images handed back.
    public init(prefix: String = "", allow: Set<String>? = nil, maxEdge: Int = 1400) {
        self.engine = LoupeMCPServer(maxEdge: maxEdge)
        self.prefix = prefix
        self.allowed = allow
    }

    private func isAllowed(_ bare: String) -> Bool {
        guard let allowed else { return true }
        return allowed.contains(bare) || allowed.contains(prefix + bare)
    }

    /// The bare name behind one the host sees, or nil if it is not on offer.
    private func bareName(_ name: String) -> String? {
        guard name.hasPrefix(prefix) else { return nil }
        let bare = String(name.dropFirst(prefix.count))
        return isAllowed(bare) ? bare : nil
    }

    public var mcpToolMetadata: [MCPToolMetadata] {
        get async {
            await engine.mcpToolMetadata.filter { isAllowed($0.name) }.map(renamed)
        }
    }

    private func renamed(_ meta: MCPToolMetadata) -> MCPToolMetadata {
        guard !prefix.isEmpty else { return meta }
        return MCPToolMetadata(
            name: prefix + meta.name, description: meta.description, parameters: meta.parameters,
            returnType: meta.returnType, returnTypeDescription: meta.returnTypeDescription,
            isAsync: meta.isAsync, isThrowing: meta.isThrowing,
            isConsequential: meta.isConsequential, annotations: meta.annotations)
    }

    /// The tools on offer, each ready to register.
    public func tools() async -> [LoupeTool] {
        await mcpToolMetadata.map { meta in
            LoupeTool(metadata: meta) { [self] arguments in
                try await callTool(meta.name, arguments: arguments)
            }
        }
    }

    public func callTool(
        _ name: String, arguments: JSONDictionary
    ) async throws -> Encodable & Sendable {
        guard let bare = bareName(name) else {
            throw LoupeError.failed("unknown tool '\(name)'")
        }
        return try await engine.callTool(bare, arguments: arguments)
    }

    /// Call a tool scoped to a run: relative paths resolve against the context's
    /// working directory and artifacts default to its evidence directory.
    public func callTool(
        _ name: String, arguments: JSONDictionary, context: LoupeCallContext
    ) async throws -> Encodable & Sendable {
        try await context.perform { try await self.callTool(name, arguments: arguments) }
    }
}
