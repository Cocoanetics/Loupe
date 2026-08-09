import ArgumentParser
import LoupeMCP

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve Loupe's verbs as an MCP server over stdio, for agents.")

    func run() async throws {
        try await LoupeMCPServer.serveOverStdio()
    }
}
