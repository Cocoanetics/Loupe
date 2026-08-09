import Darwin
import Foundation
import LoupeCore

/// A driver kept alive in its own process, addressable as `@name`.
///
/// Mac apps and simulators do not need this: the app *is* the state, it outlives
/// any single command, and each invocation simply re-attaches. A web page has no
/// such external owner — the web view dies with the process — so without a live
/// session an agent can never do the thing agents actually do: look at the page,
/// decide, act, and look again. Batching does not solve it, because batching
/// presumes you already know every step, which is precisely what a deciding
/// agent does not.
///
/// Deliberately *not* a system-wide daemon. One short-lived helper process per
/// session, started on demand, idle-expiring on its own, with no installation
/// and no separate TCC identity — it is the same signed binary, so it inherits
/// the same Accessibility and Screen Recording grants.
///
/// This file is the registry: how a session announces itself on disk and how a
/// client finds it. The wire format lives in `LiveSessionWire.swift`, the client
/// in `LiveSessionDriver.swift`, the server in `LiveSessionServer.swift`.
public enum LiveSession {

    /// Where session descriptors live.
    public static var registryRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".loupe/live", isDirectory: true)
    }

    /// What a client needs in order to reach a running session.
    public struct Descriptor: Codable, Sendable {
        public var name: String
        /// The target the session was opened on, as written.
        public var target: String
        public var port: UInt16
        /// Shared secret. The listener is loopback-only, but loopback is not a
        /// privacy boundary on a multi-user Mac, so every request carries this.
        public var token: String
        public var pid: Int32
        public var startedAt: Date

        public init(
            name: String, target: String, port: UInt16, token: String, pid: Int32,
            startedAt: Date = Date()
        ) {
            self.name = name
            self.target = target
            self.port = port
            self.token = token
            self.pid = pid
            self.startedAt = startedAt
        }

        /// A session whose process is gone is a stale file, not a session.
        public var isAlive: Bool { kill(pid, 0) == 0 }
    }

    /// A stable, readable session name for a target, so the same target always
    /// maps to the same session instead of accumulating one per invocation.
    ///
    /// Readability is the point: this name is what `session list` shows and what
    /// you type to close it. Slugifying a whole locator yields
    /// `file----tmp-lp-login-html`, so each surface contributes the part a person
    /// would actually use to identify it — a host or file name for the web, the
    /// app or device name elsewhere.
    public static func suggestedName(for target: Target) -> String {
        let raw: String
        switch target.surface {
            case .web:
                let url = URL(string: target.locator)
                raw = url?.host ?? url?.deletingPathExtension().lastPathComponent ?? target.locator
            case .mac, .sim, .live:
                raw = target.locator
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        let collapsed = cleaned.split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "session" : String(collapsed.prefix(40)).lowercased()
    }

    static func descriptorURL(_ name: String) -> URL {
        registryRoot.appendingPathComponent("\(sanitize(name)).json")
    }

    static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.isEmpty ? "session" : cleaned
    }

    public static func load(_ name: String) throws -> Descriptor {
        let url = descriptorURL(name)
        // Must match `save`'s date strategy, or every read fails silently and a
        // perfectly healthy session looks like it never started.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
            let descriptor = try? decoder.decode(Descriptor.self, from: data)
        else {
            throw LoupeError.targetNotFound(
                "no live session named '\(name)' — start one with `loupe session open <target> --as \(name)`")
        }
        guard descriptor.isAlive else {
            try? FileManager.default.removeItem(at: url)
            throw LoupeError.targetNotFound(
                "live session '\(name)' is gone (its process exited) — reopen it with "
                    + "`loupe session open \(descriptor.target) --as \(name)`")
        }
        return descriptor
    }

    public static func save(_ descriptor: Descriptor) throws {
        try FileManager.default.createDirectory(at: registryRoot, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(descriptor).write(to: descriptorURL(descriptor.name), options: .atomic)
    }

    public static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: descriptorURL(name))
    }

    /// Live sessions, dead ones swept as a side effect.
    public static func list() -> [Descriptor] {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: registryRoot, includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return
            files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Descriptor? in
                guard let data = try? Data(contentsOf: url),
                    let descriptor = try? decoder.decode(Descriptor.self, from: data)
                else { return nil }
                guard descriptor.isAlive else {
                    try? FileManager.default.removeItem(at: url)
                    return nil
                }
                return descriptor
            }
            .sorted { $0.startedAt > $1.startedAt }
    }
}
