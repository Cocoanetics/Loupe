import Foundation
import LoupeCore
import Testing

@testable import LoupeMCP

@Suite("loupe_script's two ways of naming a script")
struct ScriptToolTests {

    @Test("inline source is taken as given")
    func inlineSource() throws {
        let script = try LoupeMCPServer.scriptSource(source: "print(1)", path: nil)
        #expect(script.text == "print(1)")
        #expect(script.name == "<script>")
    }

    @Test("a path is read, and names the file so failures point at it")
    func fromPath() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("flow-\(UUID().uuidString).swift")
        try "print(2)".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let script = try LoupeMCPServer.scriptSource(source: nil, path: url.path)
        #expect(script.text == "print(2)")
        #expect(script.name == url.lastPathComponent)
    }

    /// The failure that matters: an empty script runs nothing and "passes", so
    /// a caller who forgot the argument would be told their check succeeded.
    @Test("an empty or missing script is refused, never treated as a run")
    func nothingToRunIsAnError() {
        #expect(throws: (any Error).self) {
            try LoupeMCPServer.scriptSource(source: "   \n\t ", path: nil)
        }
        #expect(throws: (any Error).self) {
            try LoupeMCPServer.scriptSource(source: nil, path: nil)
        }
    }

    @Test("asking for both is refused rather than silently picking one")
    func ambiguityIsRefused() {
        #expect(throws: (any Error).self) {
            try LoupeMCPServer.scriptSource(source: "print(1)", path: "/tmp/x.swift")
        }
    }

    @Test("an unreadable path fails with the path in the message")
    func missingFile() {
        #expect(throws: (any Error).self) {
            try LoupeMCPServer.scriptSource(source: nil, path: "/nope/does-not-exist.swift")
        }
    }
}
