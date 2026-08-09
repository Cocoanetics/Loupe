import Foundation
import LoupeCore

/// The target commands act on when none is named.
///
/// Exists because the CLI's unit of work is one command, but the *user's* unit
/// of work is a flow: look, decide, act, look again. Without a remembered
/// target, every step of that flow repeats the same quoted string —
/// `"mac:My App#main"` five times in a row — and the noise buries the one
/// thing that actually changed between steps.
///
/// Deliberately a file rather than an environment variable: a flow spans
/// separate processes, and often separate shells (an agent runs each step as its
/// own command). It is the same reason before/after sessions live on disk.
public struct CurrentTarget: Codable, Sendable {
    /// The target as written, e.g. `mac:Safari#main` or `@portal`.
    public var target: String
    /// Web viewport, carried along so the flow does not silently change size
    /// halfway through — which would make every capture differ.
    public var viewport: String?
    public var profile: String?
    public var setAt: Date

    public init(target: String, viewport: String? = nil, profile: String? = nil) {
        self.target = target
        self.viewport = viewport
        self.profile = profile
        self.setAt = Date()
    }

    /// Default location. Overridable so tests never touch a flow the user has in
    /// progress — and so they can run in parallel, which they do.
    public static let defaultStoreURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".loupe/current.json")

    /// The remembered target, or nil if none is set.
    public static func load(from storeURL: URL = defaultStoreURL) -> CurrentTarget? {
        guard let data = try? Data(contentsOf: storeURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CurrentTarget.self, from: data)
    }

    public static func save(_ current: CurrentTarget, to storeURL: URL = defaultStoreURL) throws {
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(current).write(to: storeURL, options: .atomic)
    }

    public static func clear(at storeURL: URL = defaultStoreURL) {
        try? FileManager.default.removeItem(at: storeURL)
    }

    /// Resolve an explicit target, falling back to the remembered one.
    ///
    /// - Throws: a message naming both ways to fix it when neither is available,
    ///   since "no target" is otherwise an unhelpful thing to be told.
    public static func resolve(_ explicit: String?, storeURL: URL = defaultStoreURL) throws -> Target {
        if let explicit { return try Target.parse(explicit) }
        guard let current = load(from: storeURL) else {
            throw LoupeError.targetNotFound(
                "no target given and none remembered — pass one, or run `loupe use <target>` first")
        }
        return try Target.parse(current.target)
    }
}
