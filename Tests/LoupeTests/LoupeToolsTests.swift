import Foundation
import Testing

@testable import LoupeMCP

@Suite("Composable tool set")
struct LoupeToolsTests {

    @Test func offersEveryToolByDefault() async {
        let names = await LoupeTools().mcpToolMetadata.map(\.name)
        #expect(names.contains("loupe_capture"))
        #expect(names.contains("loupe_script"))
        #expect(names.allSatisfy { $0.hasPrefix("loupe_") })
    }

    @Test func prefixAndAllowListApplyTogether() async throws {
        let tools = LoupeTools(prefix: "ui_", allow: ["loupe_doctor", "ui_loupe_list_targets"])
        let names = await tools.tools().map(\.name).sorted()
        #expect(names == ["ui_loupe_doctor", "ui_loupe_list_targets"])
    }

    @Test func refusesWhatIsNotOnOffer() async {
        let tools = LoupeTools(prefix: "ui_", allow: ["loupe_doctor"])
        await #expect(throws: (any Error).self) {
            _ = try await tools.callTool("ui_loupe_capture", arguments: [:])
        }
        await #expect(throws: (any Error).self) {
            // Right tool, but without the prefix the host mounted it under.
            _ = try await tools.callTool("loupe_doctor", arguments: [:])
        }
    }

    @Test func contextScopesRelativePathsAndEvidence() async {
        let base = URL(fileURLWithPath: "/tmp/run-1", isDirectory: true)
        let evidence = URL(fileURLWithPath: "/tmp/run-1/evidence", isDirectory: true)
        await LoupeCallContext(workingDirectory: base, evidenceDirectory: evidence).perform {
            #expect(LoupeCallContext.resolve("flows/a.swift").path == "/tmp/run-1/flows/a.swift")
            #expect(LoupeCallContext.resolve("/abs/b.swift").path == "/abs/b.swift")
            #expect(LoupeMCPServer.directory(nil) == evidence)
            #expect(LoupeMCPServer.directory("/elsewhere")?.path == "/elsewhere")
        }
        #expect(LoupeMCPServer.directory(nil) == nil)
    }

    @Test func hostComesFromTheEnvironment() throws {
        #expect(try LoupeHost.configured(environment: [:]) == nil)
        #expect(try LoupeHost.configured(environment: ["LOUPE_HOST": " "]) == nil)
        let host = try LoupeHost.configured(
            environment: ["LOUPE_HOST": "http://127.0.0.1:9000/mcp", "LOUPE_HOST_PREFIX": "ui_"])
        #expect(host?.url.absoluteString == "http://127.0.0.1:9000/mcp")
        #expect(host?.toolPrefix == "ui_")
        #expect(throws: (any Error).self) {
            _ = try LoupeHost.configured(environment: ["LOUPE_HOST": "/tmp/host.sock"])
        }
    }
}
