import Darwin
import Foundation
import LoupeCore

/// A ``UIDriver`` that forwards every verb to a live session's process.
///
/// Because it is just another driver, `capture`, `describe`, `act`, `before` and
/// `after` all work against `@name` with no changes anywhere above this type.
public final class LiveSessionDriver: UIDriver, @unchecked Sendable {
    private let descriptor: LiveSession.Descriptor

    public init(name: String) throws {
        self.descriptor = try LiveSession.load(name)
    }

    public var targetDescription: String { "@\(descriptor.name) → \(descriptor.target)" }

    public func prepare() async throws {
        // The session prepared its driver when it opened; a ping just proves the
        // process is still answering rather than merely still running.
        _ = try send(LiveSession.Request(token: descriptor.token, verb: "ping"))
    }

    public func capture(_ options: CaptureOptions) async throws -> Capture {
        let response = try send(
            LiveSession.Request(
                token: descriptor.token, verb: "capture", capture: LiveSession.CaptureWire(options)))
        guard let wire = response.capture else {
            throw LoupeError.failed("live session returned no image")
        }
        return wire.capture
    }

    public func describe(_ options: DescribeOptions) async throws -> [UINode] {
        let response = try send(
            LiveSession.Request(
                token: descriptor.token, verb: "describe",
                describe: LiveSession.DescribeWire(options)))
        return response.nodes ?? []
    }

    public func perform(_ action: UIAction) async throws -> ActionResult {
        let response = try send(
            LiveSession.Request(
                token: descriptor.token, verb: "act", action: LiveSession.ActionWire(action)))
        guard let wire = response.action else {
            throw LoupeError.failed("live session returned no action result")
        }
        return wire.result
    }

    /// Does nothing on purpose: the session outlives this command, which is the
    /// entire point. Close it explicitly with `loupe session close`.
    public func shutdown() async {}

    private func send(_ request: LiveSession.Request) throws -> LiveSession.Response {
        let socketFD = try connectToSession()
        defer { close(socketFD) }

        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        try payload.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let written = write(socketFD, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                guard written > 0 else { throw LoupeError.failed("write to live session failed") }
                sent += written
            }
        }
        // Signal end-of-request so the server can stop reading without needing a
        // length prefix.
        Darwin.shutdown(socketFD, SHUT_WR)

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let bytesRead = read(socketFD, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            data.append(contentsOf: buffer[0..<bytesRead])
        }
        guard !data.isEmpty else {
            throw LoupeError.failed("live session closed the connection without replying")
        }
        let response = try JSONDecoder().decode(LiveSession.Response.self, from: data)
        if !response.succeeded { throw LoupeError.failed(response.error ?? "live session error") }
        return response
    }

    /// A connected socket to the session's loopback listener.
    ///
    /// A refused connection means the descriptor outlived the process that wrote
    /// it — a pid can be recycled, so `isAlive` is not proof — and a descriptor
    /// nobody can reach is worse than none, so it is dropped here.
    private func connectToSession() throws -> Int32 {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw LoupeError.failed("could not create socket") }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = descriptor.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(socketFD)
            LiveSession.remove(descriptor.name)
            throw LoupeError.failed(
                "live session '\(descriptor.name)' is not answering on port \(descriptor.port); "
                    + "it has been forgotten. Reopen it.")
        }
        return socketFD
    }
}
