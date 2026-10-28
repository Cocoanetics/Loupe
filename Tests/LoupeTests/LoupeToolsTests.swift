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

    @Test func tokenGoesOutAsBearerHeader() throws {
        let direct = try LoupeHost.configured(
            environment: ["LOUPE_HOST": "http://127.0.0.1:9000/mcp", "LOUPE_HOST_TOKEN": " abc123\n"])
        #expect(direct?.headers == ["Authorization": "Bearer abc123"])

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("loupe-token-\(UUID())")
        try "from-file\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let viaFile = try LoupeHost.configured(
            environment: ["LOUPE_HOST": "https://mc.example/mcp", "LOUPE_HOST_TOKEN_FILE": file.path])
        #expect(viaFile?.headers == ["Authorization": "Bearer from-file"])

        // The variable wins over the file.
        let both = try LoupeHost.configured(
            environment: [
                "LOUPE_HOST": "https://mc.example/mcp", "LOUPE_HOST_TOKEN": "env",
                "LOUPE_HOST_TOKEN_FILE": file.path
            ])
        #expect(both?.headers["Authorization"] == "Bearer env")

        let none = try LoupeHost.configured(environment: ["LOUPE_HOST": "https://mc.example/mcp"])
        #expect(none?.headers.isEmpty == true)
        #expect(throws: (any Error).self) {
            _ = try LoupeHost.configured(
                environment: ["LOUPE_HOST": "https://mc.example/mcp", "LOUPE_HOST_TOKEN_FILE": "/nope/x"])
        }
    }

    @Test func secretsOnlyTravelToLoopbackOrHTTPS() throws {
        func allows(_ url: String) -> Bool {
            LoupeHost(url: URL(string: url)!).allowsSecrets
        }
        #expect(allows("http://127.0.0.1:9000/mcp"))
        #expect(allows("http://localhost:9000/mcp"))
        #expect(allows("http://[::1]:9000/mcp"))
        #expect(allows("https://mc.example/mcp"))
        #expect(!allows("http://mc.example/mcp"))
        #expect(!allows("http://192.168.1.5:9000/mcp"))
        #expect(!allows("http://127.0.0.1.evil.example/mcp"))

        #expect(LoupeHost.carriesSecrets(["loupe", "set", "pw", "{{PASSWORD}}"]))
        #expect(!LoupeHost.carriesSecrets(["loupe", "press", "Save"]))
    }

    @Test func tokenOnlyTravelsToLoopbackOrHTTPS() throws {
        func configure(_ url: String, token: String? = "secret") throws -> LoupeHost? {
            var environment = ["LOUPE_HOST": url]
            environment["LOUPE_HOST_TOKEN"] = token
            return try LoupeHost.configured(environment: environment)
        }
        #expect(try configure("http://127.0.0.1:9000/mcp") != nil)
        #expect(try configure("http://localhost:9000/mcp") != nil)
        #expect(try configure("http://[::1]:9000/mcp") != nil)
        #expect(try configure("https://mc.example/mcp") != nil)
        #expect(try configure("http://mc.example/mcp", token: nil) != nil)
        #expect(throws: (any Error).self) { _ = try configure("http://mc.lan:9000/mcp") }
        #expect(throws: (any Error).self) { _ = try configure("http://192.168.1.5:9000/mcp") }
    }

    @Test func hostedDoctorKeepsJSONAndStatus() {
        func report(allGood: Bool) -> String {
            "{\"surfaces\":[],\"lines\":[\"Accessibility ✗\"],\"allGood\":\(allGood)}"
        }
        let bad = report(allGood: false)
        let asJSON = LoupeHost.doctorOutput(bad, json: true)
        #expect(asJSON.lines == [bad])
        #expect(asJSON.allGood == false)

        let asText = LoupeHost.doctorOutput(bad, json: false)
        #expect(asText.lines == ["Accessibility ✗"])
        #expect(asText.allGood == false)

        #expect(LoupeHost.doctorOutput(report(allGood: true), json: true).allGood == true)
        #expect(LoupeHost.doctorOutput("not json", json: true).allGood == nil)
    }
}
