import Darwin
import Foundation
import LoupeCore

/// Runs inside the session's own process: owns the real driver and answers
/// requests until it is closed or goes idle.
public final class LiveSessionServer: @unchecked Sendable {
    private let name: String
    private let target: Target
    private let options: Loupe.Options
    private let idleTimeout: TimeInterval
    private let token = UUID().uuidString

    private var driver: (any UIDriver)?
    private var shouldStop = false

    /// Tracks liveness for the idle watchdog. An actor rather than a lock:
    /// NSLock is unavailable from async contexts under Swift 6, and this is
    /// touched from the connection handler and the watchdog task.
    private actor Clock {
        private var lastUsed = Date()
        func touch() { lastUsed = Date() }
        func idleSeconds() -> TimeInterval { Date().timeIntervalSince(lastUsed) }
    }
    private let clock = Clock()

    /// A bound listening socket and the port the kernel picked for it.
    private struct Listener {
        var socketFD: Int32
        var port: UInt16
    }

    public init(
        name: String, target: Target, options: Loupe.Options = .default,
        idleTimeout: TimeInterval = 900
    ) {
        self.name = name
        self.target = target
        self.options = options
        self.idleTimeout = idleTimeout
    }

    /// Binds, publishes the descriptor, and serves until closed. Never returns
    /// normally except on shutdown.
    public func run() async throws {
        let driver = try await MainActor.run { try Loupe.driver(for: target, options: options) }
        try await driver.prepare()
        self.driver = driver

        let listener = try bindLoopback()
        try publish(port: listener.port)

        defer {
            close(listener.socketFD)
            LiveSession.remove(name)
        }

        startIdleWatchdog()

        for await clientFD in acceptedConnections(on: listener.socketFD) {
            await handle(clientFD)
            if shouldStop { break }
        }
        await driver.shutdown()
    }

    /// Listen on an ephemeral loopback port. Loopback because nothing about this
    /// belongs on a network; ephemeral because a fixed port would collide with
    /// the second session and with whatever else the user is running.
    private func bindLoopback() throws -> Listener {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw LoupeError.failed("could not create listening socket") }
        var yes: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0  // ephemeral
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(socketFD, 8) == 0 else {
            throw LoupeError.failed("could not listen on loopback")
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &actual) {
            _ = $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        return Listener(socketFD: socketFD, port: UInt16(bigEndian: actual.sin_port))
    }

    /// Write the descriptor that makes this session findable, and say so on
    /// stderr — the caller usually backgrounded us and has nothing else to go on.
    private func publish(port: UInt16) throws {
        try LiveSession.save(
            LiveSession.Descriptor(
                name: name, target: target.description, port: port, token: token,
                pid: ProcessInfo.processInfo.processIdentifier))
        FileHandle.standardError.write(
            Data("loupe: session '\(name)' listening on 127.0.0.1:\(port)\n".utf8))
    }

    /// Accept on a dedicated thread: the main actor must stay free for WebKit,
    /// and a blocking accept() would otherwise squat a cooperative thread.
    private func acceptedConnections(on listenFD: Int32) -> AsyncStream<Int32> {
        AsyncStream<Int32> { continuation in
            let thread = Thread {
                while true {
                    let clientFD = accept(listenFD, nil, nil)
                    if clientFD < 0 { continuation.finish(); return }
                    continuation.yield(clientFD)
                }
            }
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    private func startIdleWatchdog() {
        guard idleTimeout > 0 else { return }
        let clock = self.clock
        let name = self.name
        let timeout = self.idleTimeout
        Task.detached {
            while true {
                try? await Task.sleep(for: .seconds(30))
                let idle = await clock.idleSeconds()
                guard idle > timeout else { continue }
                // Exiting is the cleanup: the descriptor goes with it, and a stale
                // web view is exactly what we do not want lingering on someone's Mac.
                FileHandle.standardError.write(
                    Data("loupe: session '\(name)' idle for \(Int(idle))s — exiting\n".utf8))
                LiveSession.remove(name)
                exit(0)
            }
        }
    }

    private func handle(_ clientFD: Int32) async {
        defer { close(clientFD) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let bytesRead = read(clientFD, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            data.append(contentsOf: buffer[0..<bytesRead])
            if data.last == 0x0A { break }
        }
        guard !data.isEmpty else { return }

        var response = LiveSession.Response(succeeded: false)
        do {
            let request = try JSONDecoder().decode(LiveSession.Request.self, from: data)
            guard request.token == token else {
                response.error = "bad token"
                try? reply(response, to: clientFD)
                return
            }
            await clock.touch()
            response = try await perform(request)
        } catch {
            response = LiveSession.Response(
                succeeded: false, error: (error as? LoupeError)?.errorDescription ?? "\(error)")
        }
        try? reply(response, to: clientFD)
    }

    private func perform(_ request: LiveSession.Request) async throws -> LiveSession.Response {
        guard let driver else { throw LoupeError.failed("session has no driver") }
        switch request.verb {
            case "ping":
                return LiveSession.Response(succeeded: true, info: driver.targetDescription)
            case "capture":
                let shot = try await driver.capture(request.capture?.options ?? .default)
                return LiveSession.Response(
                    succeeded: true, capture: LiveSession.CaptureResultWire(shot))
            case "describe":
                let nodes = try await driver.describe(request.describe?.options ?? .default)
                return LiveSession.Response(succeeded: true, nodes: nodes)
            case "act":
                guard let action = request.action?.action else {
                    throw LoupeError.failed("unrecognized action")
                }
                // Route through Loupe.perform so a session honors waitFor too.
                let result = try await Loupe.perform(action, on: driver)
                return LiveSession.Response(
                    succeeded: true, action: LiveSession.ActionResultWire(result))
            case "close":
                shouldStop = true
                return LiveSession.Response(succeeded: true, info: "closing")
            default:
                throw LoupeError.failed("unknown verb '\(request.verb)'")
        }
    }

    private func reply(_ response: LiveSession.Response, to clientFD: Int32) throws {
        let data = try JSONEncoder().encode(response)
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let written = Darwin.write(
                    clientFD, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                guard written > 0 else { throw LoupeError.failed("write failed") }
                sent += written
            }
        }
    }
}
