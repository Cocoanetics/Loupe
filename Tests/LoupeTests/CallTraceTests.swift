import Foundation
import LoupeKit
import Testing

@testable import LoupeCore
@testable import LoupeMCP

@Suite("Bounded, traced calls")
struct CallTraceTests {

    @Test func timeoutNamesTheStepItWasStuckIn() async throws {
        let started = Date()
        do {
            _ = try await CallTrace.run("loupe_list_targets", seconds: 0.3) {
                try await CallTrace.during("`xcrun simctl list devices --json`") {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
            Issue.record("the call should have run out of time")
        } catch let error as CallTrace.TimedOut {
            #expect(error.message.contains("loupe_list_targets did not finish within 0s"))
            #expect(error.message.contains("stuck in: `xcrun simctl list devices --json` (for"))
        }
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func concurrentStepsAreAllNamed() async throws {
        do {
            _ = try await CallTrace.run("loupe_list_targets", seconds: 0.3) {
                async let sims: Void = CallTrace.during("listing simulators") {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
                try await CallTrace.during("reading the windows of Crateflow (pid 42)") {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
                try await sims
            }
            Issue.record("the call should have run out of time")
        } catch let error as CallTrace.TimedOut {
            #expect(error.message.contains("listing simulators"))
            #expect(error.message.contains("reading the windows of Crateflow (pid 42)"))
        }
    }

    @Test func afterTheLastStepIsReportedWhenNothingIsOpen() async throws {
        do {
            _ = try await CallTrace.run("loupe_capture", seconds: 0.3) {
                CallTrace.mark("capturing the window")
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            Issue.record("the call should have run out of time")
        } catch let error as CallTrace.TimedOut {
            #expect(error.message.contains("stuck in: after capturing the window"))
        }
    }

    @Test func aCallInTimeReturnsItsValue() async throws {
        let value = try await CallTrace.run("loupe_doctor", seconds: 5) {
            CallTrace.during("probing") { 42 }
        }
        #expect(value == 42)
    }

    @Test func deadlineKeepsTheCallersTaskLocals() async throws {
        let trace = CallTrace(call: "loupe_describe")
        let seen = try await CallTrace.$active.withValue(trace) {
            try await Deadline.run(seconds: 5, "probe") { CallTrace.active?.call }
        }
        #expect(seen == "loupe_describe")
    }

    @Test func budgets() {
        #expect(LoupeMCPServer.budget(for: "loupe_list_targets", environment: [:]) == 60)
        #expect(LoupeMCPServer.budget(for: "loupe_capture", environment: [:]) == 240)
        #expect(LoupeMCPServer.budget(for: "loupe_record", environment: [:]) == 360)
        // A script's own timeout can be ignored by a loop that never suspends, so
        // the call keeps an outer limit past it.
        #expect(LoupeMCPServer.budget(for: "loupe_script", environment: [:]) == 180)
        #expect(
            LoupeMCPServer.budget(for: "loupe_script", arguments: ["timeout": .integer(600)], environment: [:])
                == 660)
        let tight = ["LOUPE_CALL_TIMEOUT": "30"]
        #expect(LoupeMCPServer.budget(for: "loupe_list_targets", environment: tight) == 30)
        #expect(LoupeMCPServer.budget(for: "loupe_capture", environment: tight) == 30)
        #expect(LoupeMCPServer.budget(for: "loupe_record", environment: tight) == 360)
        #expect(LoupeMCPServer.budget(for: "loupe_script", environment: tight) == 180)
    }

    @Test func logLinesCarryThePidAndCanBeTurnedOff() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-calls-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        let log = CallLog(environment: ["LOUPE_CALL_LOG": file.path])
        #expect(log.path == file.path)
        log.write("#1 loupe_list_targets: start")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("pid=\(ProcessInfo.processInfo.processIdentifier) #1 loupe_list_targets: start"))
        #expect(CallLog(environment: ["LOUPE_CALL_LOG": "off"]).path == nil)
    }

    @Test func interpolatedSecretsNeverReachTheLog() throws {
        let secret = "tok-\(UUID().uuidString)"
        let link = try EnvironmentInterpolation.expand(
            "myapp://login?token={{LOUPE_TEST_TOKEN}}", environment: ["LOUPE_TEST_TOKEN": secret])
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-calls-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: file) }
        CallLog(environment: ["LOUPE_CALL_LOG": file.path])
            .write("#1 loupe_act: `xcrun simctl openurl booted \(link)`")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains(secret))
        #expect(text.contains("myapp://login?token=••••"))
    }

    @Test func inventoryFromAnOlderHostStillDecodes() throws {
        let json = #"{"apps":[],"simulators":[],"accessibilityTrusted":true}"#
        let inventory = try JSONDecoder().decode(Inventory.self, from: Data(json.utf8))
        #expect(inventory.simulatorsError == nil)
    }
}
