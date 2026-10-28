import ArgumentParser
import LoupeMCP

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve Loupe's verbs as an MCP server over stdio, for agents.",
        discussion: "With LOUPE_HOST set, relays to that host's MCP endpoint instead of driving the UI itself.")

    func run() async throws {
        if let host = try LoupeHost.configured() {
            try await LoupeRelayServer.serveOverStdio(host: host)
        } else {
            try await LoupeMCPServer.serveOverStdio()
        }
    }
}
