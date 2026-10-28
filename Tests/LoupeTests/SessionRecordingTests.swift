import Foundation
import LoupeCore
@testable import LoupeKit
import Testing

/// A recorder that films nothing and counts how often it was stopped.
private final class FakeRecorder: RecordingDriver, @unchecked Sendable {
    let targetDescription = "fake"
    private let lock = NSLock()
    private var stops = 0

    init(actionDuration: Double) {}

    var stopCount: Int { lock.withLock { stops } }

    func capture(_ options: CaptureOptions) async throws -> Capture { throw LoupeError.unsupported("fake") }
    func describe(_ options: DescribeOptions) async throws -> [UINode] { [] }
    func perform(_ action: UIAction) async throws -> ActionResult { ActionResult(message: "done") }

    func startRecording(to url: URL, options: RecordOptions) async throws -> any RecordingHandle {
        Handle(owner: self, url: url)
    }

    private struct Handle: RecordingHandle {
        let owner: FakeRecorder
        let url: URL

        func stop() async throws -> RecordingResult {
            owner.lock.withLock { owner.stops += 1 }
            return RecordingResult(url: url, duration: 0, bytes: 1)
        }
    }
}

@Suite struct SessionRecordingTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID()).mov")
    }

    @Test func stopHandsBackTheRecordingOnce() async throws {
        let recorder = SessionRecorder()
        let driver = FakeRecorder(actionDuration: 0)
        let url = scratch()
        try await recorder.start(on: driver, url: url, options: RecordOptions(maxDuration: 10))
        #expect(await recorder.isRecording)
        await #expect(throws: LoupeError.self) {
            try await recorder.start(on: driver, url: url, options: .default)
        }
        let result = try await recorder.stop()
        #expect(result.url == url)
        #expect(driver.stopCount == 1)
        #expect(await !recorder.isRecording)
        await #expect(throws: LoupeError.self) { _ = try await recorder.stop() }
    }

    @Test func theLimitStopsItAndStopStillFindsTheResult() async throws {
        let recorder = SessionRecorder()
        let driver = FakeRecorder(actionDuration: 0)
        try await recorder.start(on: driver, url: scratch(), options: RecordOptions(maxDuration: 0.2))
        try await Task.sleep(for: .milliseconds(600))
        #expect(driver.stopCount == 1)
        let result = try await recorder.stop()
        #expect(result.notes.contains { $0.contains("limit") })
        #expect(driver.stopCount == 1)
    }

    @Test func aDriverThatCannotRecordIsRefused() async throws {
        let recorder = SessionRecorder()
        await #expect(throws: LoupeError.self) {
            try await recorder.start(on: NotARecorder(), url: scratch(), options: .default)
        }
    }

    @Test func abandonStopsWithoutKeepingAnything() async throws {
        let recorder = SessionRecorder()
        let driver = FakeRecorder(actionDuration: 0)
        try await recorder.start(on: driver, url: scratch(), options: .default)
        await recorder.abandon()
        #expect(driver.stopCount == 1)
        await #expect(throws: LoupeError.self) { _ = try await recorder.stop() }
    }

    @Test func recordRequestsAndResultsRoundTripTheWire() throws {
        var options = RecordOptions(maxDuration: 42)
        options.region = .element("Login", padding: 12)
        let wire = LiveSession.RecordWire(url: URL(fileURLWithPath: "/tmp/a.mov"), options: options)
        let decoded = try JSONDecoder().decode(LiveSession.RecordWire.self, from: try JSONEncoder().encode(wire))
        #expect(decoded.options.maxDuration == 42)
        guard case .element(let needle, let padding)? = decoded.options.region else {
            Issue.record("region lost"); return
        }
        #expect(needle == "Login" && padding == 12)

        var result = RecordingResult(url: URL(fileURLWithPath: "/tmp/a.mov"), duration: 3, bytes: 9, notes: ["n"])
        result.region = Frame(x: 1, y: 2, width: 3, height: 4)
        result.scale = 3
        let back = try JSONDecoder().decode(
            LiveSession.RecordingResultWire.self,
            from: try JSONEncoder().encode(LiveSession.RecordingResultWire(result))
        ).result
        #expect(back.region == result.region && back.scale == 3 && back.notes == ["n"] && back.bytes == 9)
    }

    @Test func untilSpecsSplitLikeWait() {
        guard case .until(let nodes, let failures, let timeout) = RecordStop.until("Dashboard|!Invalid", timeout: 7)
        else { Issue.record("not until"); return }
        #expect(nodes == ["Dashboard"] && failures == ["Invalid"] && timeout == 7)
    }

    @Test func liveSessionsAreRecordingDrivers() {
        #expect((LiveSessionDriver.self as Any.Type) is any RecordingDriver.Type)
    }
}

private final class NotARecorder: UIDriver, @unchecked Sendable {
    let targetDescription = "web:fake"
    func capture(_ options: CaptureOptions) async throws -> Capture { throw LoupeError.unsupported("fake") }
    func describe(_ options: DescribeOptions) async throws -> [UINode] { [] }
    func perform(_ action: UIAction) async throws -> ActionResult { ActionResult(message: "ok") }
}
