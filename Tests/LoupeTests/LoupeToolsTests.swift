import Foundation
import LoupeKit
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

@Suite("Recording tool")
struct RecordToolTests {
    @Test func recordIsOnOffer() async {
        let names = await LoupeTools().mcpToolMetadata.map(\.name)
        #expect(names.contains("loupe_record"))
    }

    @Test func aCallMustSayWhenToStop() throws {
        func request(duration: String? = nil, until: String? = nil) -> LoupeMCPServer.RecordRequest {
            LoupeMCPServer.RecordRequest(
                out: nil, duration: duration, until: until, region: nil, element: nil, gif: false, fps: nil,
                maxWidth: nil, appStore: false, appStoreDevice: nil)
        }
        var tuned = request()
        tuned.tail = "2s"
        tuned.timeout = 4
        tuned.padding = 3
        tuned.element = "Login"
        tuned.threshold = 0.5
        tuned.loop = false
        tuned.gif = true
        guard case .after(let tail) = try tuned.stop(hasActions: true) else { Issue.record("no tail"); return }
        #expect(tail == 2)
        tuned.until = "Done"
        guard case .until(_, _, let timeout) = try tuned.stop(hasActions: false) else {
            Issue.record("no until"); return
        }
        #expect(timeout == 4)
        guard case .element(_, let padding)? = try tuned.crop() else { Issue.record("no element"); return }
        #expect(padding == 3)
        let gif = try tuned.request(for: try LoupeKit.Target.parse("sim:booted")).gif
        #expect(gif?.threshold == 0.5 && gif?.loop == false)
        #expect(throws: (any Error).self) { try request().stop(hasActions: false) }
        #expect(throws: (any Error).self) { try request(duration: "5s", until: "X").stop(hasActions: false) }
        guard case .after(let tail) = try request().stop(hasActions: true) else { Issue.record("no tail"); return }
        #expect(tail == 0.5)
        guard case .after(let seconds) = try request(duration: "5s").stop(hasActions: false) else {
            Issue.record("no duration"); return
        }
        #expect(seconds == 5)
        guard case .until = try request(until: "Done").stop(hasActions: false) else {
            Issue.record("no until"); return
        }
    }

    @Test func outputsFollowTheCallContext() async throws {
        let evidence = URL(fileURLWithPath: "/tmp/run-9/evidence", isDirectory: true)
        let request = LoupeMCPServer.RecordRequest(
            out: nil, duration: "1s", until: nil, region: nil, element: nil, gif: true, fps: nil,
            maxWidth: nil, appStore: false, appStoreDevice: nil)
        let schema = await LoupeTools().mcpToolMetadata.first { $0.name == "loupe_record" }
        #expect(schema?.parameters.contains { $0.name == "steps" } == true)
        let target = try LoupeKit.Target.parse("sim:booted")
        try await LoupeCallContext(workingDirectory: nil, evidenceDirectory: evidence).perform {
            let files = try request.request(for: target)
            #expect(files.output.deletingLastPathComponent().path == evidence.path)
            #expect(files.gifURL != nil)
        }
        var named = request
        named.out = "clip.gif"
        named.gif = false
        let gifOnly = named
        let base = URL(fileURLWithPath: "/tmp/run-9", isDirectory: true)
        try await LoupeCallContext(workingDirectory: base, evidenceDirectory: nil).perform {
            let files = try gifOnly.request(for: target)
            #expect(files.output.path == "/tmp/run-9/clip.gif" && files.gifOnly)
        }
        named.appStore = true
        let appStoreGIF = named
        #expect(throws: (any Error).self) { try appStoreGIF.request(for: target) }
        named.out = "clip.mp4"
        named.appStoreDevice = "tv"
        let unknownDevice = named
        #expect(throws: (any Error).self) { try unknownDevice.request(for: target) }
        named.appStoreDevice = "Mac"
        #expect(try named.request(for: target).family == .mac)
    }
}
