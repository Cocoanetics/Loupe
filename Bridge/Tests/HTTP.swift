import Darwin
import Foundation

/// The smallest HTTP server that can carry the bridge's traffic.
///
/// Deliberately hand-rolled on BSD sockets rather than Network.framework: this
/// runs inside a UI-test process on a simulator, where the run loop belongs to
/// XCTest, and a blocking accept loop on the test's own thread is both simpler
/// and easier to reason about than juggling queues with the test runtime.
struct Listener {
    private let descriptor: Int32

    init(port: UInt16) throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BridgeError("socket() failed, errno \(errno)") }
        var reuse: Int32 = 1
        setsockopt(
            descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse,
            socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        // The simulator shares the host's network stack, so binding here is
        // directly reachable from the Mac with no forwarding.
        address.sin_addr.s_addr = INADDR_ANY

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw BridgeError("bind(\(port)) failed, errno \(errno)") }
        guard listen(descriptor, 16) == 0 else {
            throw BridgeError("listen() failed, errno \(errno)")
        }
    }

    func accept() -> Connection? {
        let client = Darwin.accept(descriptor, nil, nil)
        return client >= 0 ? Connection(descriptor: client) : nil
    }
}

struct Connection {
    let descriptor: Int32

    func close() { Darwin.close(descriptor) }

    /// Reads headers, then exactly `Content-Length` bytes of body.
    ///
    /// A single read would truncate any tree-sized request and, worse, would do
    /// so intermittently — the failure would look like a parsing bug.
    func readRequest() -> Request? {
        var raw = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)

        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { return nil }
            raw.append(contentsOf: buffer[0..<count])
            headerEnd = raw.range(of: Data("\r\n\r\n".utf8))
        }
        guard let headerEnd else { return nil }

        let headerText = String(decoding: raw[raw.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var body = Data(raw[headerEnd.upperBound...])
        let expected = Request.contentLength(in: headerText)
        while body.count < expected {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            body.append(contentsOf: buffer[0..<count])
        }
        return Request(headerText: headerText, body: body)
    }

    func send(status: Int, json: [String: Any]) {
        let payload =
            (try? JSONSerialization.data(withJSONObject: json, options: []))
            ?? Data(#"{"error":"could not encode response"}"#.utf8)
        var response = Data(
            ("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
                + "Content-Type: application/json\r\n"
                + "Content-Length: \(payload.count)\r\n"
                + "Connection: close\r\n\r\n").utf8)
        response.append(payload)
        response.withUnsafeBytes { pointer in
            var sent = 0
            while sent < pointer.count {
                let wrote = write(descriptor, pointer.baseAddress!.advanced(by: sent), pointer.count - sent)
                if wrote <= 0 { break }
                sent += wrote
            }
        }
    }
}

/// One parsed request: the path, the headers the bridge cares about, and a JSON
/// body decoded into a dictionary.
struct Request {
    let path: String
    let headers: [String: String]
    let body: [String: Any]

    init(headerText: String, body rawBody: Data) {
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let target = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        // Query strings are not used, but a stray one should not change routing.
        path = target.split(separator: "?").first.map(String.init) ?? "/"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name.lowercased()] = value
        }
        self.headers = headers
        self.body =
            (try? JSONSerialization.jsonObject(with: rawBody)) as? [String: Any] ?? [:]
    }

    func header(_ name: String) -> String? { headers[name.lowercased()] }

    static func contentLength(in headerText: String) -> Int {
        for line in headerText.components(separatedBy: "\r\n")
        where line.lowercased().hasPrefix("content-length:") {
            return Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        }
        return 0
    }

    func string(_ key: String) throws -> String {
        guard let value = body[key] as? String else {
            throw BridgeError("missing or non-string '\(key)'")
        }
        return value
    }

    func double(_ key: String) throws -> Double {
        if let value = body[key] as? Double { return value }
        if let value = body[key] as? Int { return Double(value) }
        throw BridgeError("missing or non-numeric '\(key)'")
    }
}
