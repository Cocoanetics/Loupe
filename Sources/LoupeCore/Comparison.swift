import Foundation

/// Persisted before/after pair.
///
/// Sessions live on disk so `before` and `after` can be separate CLI
/// invocations — separate agent turns, even, with a code change and a rebuild in
/// between. That is the whole point: the "before" has to be captured before the
/// fix exists.
public struct ComparisonSession: Codable, Sendable {
    public var name: String
    /// The target **as written**, e.g. `mac:TextEdit` — re-parseable, so `after`
    /// can resolve it in a later process. Deliberately not the driver's resolved
    /// description (`mac:TextEdit#0 'note.txt' (pid 71720)`), which is for humans
    /// and whose pid is meaningless once the app restarts.
    public var target: String
    /// What the driver reported it actually captured, for the caption and for
    /// telling two similar windows apart afterwards.
    public var resolved: String?
    public var beforeAt: Date?
    public var afterAt: Date?
    public var scale: Double
    public var notes: [String]

    public init(
        name: String, target: String, resolved: String? = nil, beforeAt: Date? = nil,
        afterAt: Date? = nil, scale: Double = 1, notes: [String] = []
    ) {
        self.name = name
        self.target = target
        self.resolved = resolved
        self.beforeAt = beforeAt
        self.afterAt = afterAt
        self.scale = scale
        self.notes = notes
    }
}

/// Everything ``ComparisonStore/recordAfter(name:capture:tolerance:)`` produces.
///
/// A named type rather than a tuple: the three values travel together through
/// two more layers, and `outcome.report` reads better at every call site than
/// remembering which position the report occupies.
public struct ComparisonOutcome: Sendable {
    /// The session as saved, with both timestamps filled in.
    public var session: ComparisonSession
    public var report: DiffReport
    /// The rendered BEFORE | AFTER image.
    public var composite: Data

    public init(session: ComparisonSession, report: DiffReport, composite: Data) {
        self.session = session
        self.report = report
        self.composite = composite
    }
}

/// Filesystem store for comparison sessions, `~/.loupe/sessions/<name>/`.
public struct ComparisonStore: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        self.root =
            root
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".loupe/sessions", isDirectory: true)
    }

    private func dir(_ name: String) -> URL {
        root.appendingPathComponent(sanitize(name), isDirectory: true)
    }

    private func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        // Dots are allowed so issue-style names like `v1.2` survive, which leaves
        // `.` and `..` as real traversal risks: both are legal filenames here and
        // would resolve to the store root or its parent.
        guard !cleaned.isEmpty, cleaned.contains(where: { $0 != "." }) else { return "session" }
        return cleaned
    }

    public func beforeURL(_ name: String) -> URL {
        dir(name).appendingPathComponent("before.png")
    }
    public func afterURL(_ name: String) -> URL {
        dir(name).appendingPathComponent("after.png")
    }
    public func compareURL(_ name: String) -> URL {
        dir(name).appendingPathComponent("compare.png")
    }
    private func metaURL(_ name: String) -> URL {
        dir(name).appendingPathComponent("session.json")
    }

    public func load(_ name: String) throws -> ComparisonSession? {
        let url = metaURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ComparisonSession.self, from: Data(contentsOf: url))
    }

    public func save(_ session: ComparisonSession) throws {
        try FileManager.default.createDirectory(
            at: dir(session.name), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(session).write(to: metaURL(session.name), options: .atomic)
    }

    public func list() throws -> [ComparisonSession] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return entries.compactMap { try? load($0.lastPathComponent) }.compactMap { $0 }
            .sorted { ($0.afterAt ?? $0.beforeAt ?? .distantPast) > ($1.afterAt ?? $1.beforeAt ?? .distantPast) }
    }

    /// Record the "before" side.
    /// - Parameter target: the target string as the caller wrote it, so `after`
    ///   can re-resolve it in a later process.
    @discardableResult
    public func recordBefore(name: String, capture: Capture, target: String) throws
        -> ComparisonSession {
        try FileManager.default.createDirectory(at: dir(name), withIntermediateDirectories: true)
        try capture.png.write(to: beforeURL(name), options: .atomic)
        // A new "before" invalidates any stale "after" from a previous round.
        try? FileManager.default.removeItem(at: afterURL(name))
        try? FileManager.default.removeItem(at: compareURL(name))
        var session =
            (try? load(name))
            ?? ComparisonSession(name: name, target: target)
        session.target = target
        session.resolved = capture.target
        session.beforeAt = capture.timestamp
        session.afterAt = nil
        session.scale = capture.scale
        session.notes = capture.notes
        try save(session)
        return session
    }

    /// Record the "after" side and produce the comparison.
    ///
    public func recordAfter(
        name: String, capture: Capture, tolerance: Int = ImageOps.defaultTolerance
    ) throws -> ComparisonOutcome {
        guard var session = try load(name), session.beforeAt != nil,
            FileManager.default.fileExists(atPath: beforeURL(name).path)
        else {
            throw LoupeError.failed(
                "no 'before' recorded for session '\(name)' — run `loupe before \(name) <target>` first")
        }
        try capture.png.write(to: afterURL(name), options: .atomic)
        session.afterAt = capture.timestamp
        session.resolved = capture.target

        let beforeData = try Data(contentsOf: beforeURL(name))
        let report = try ImageOps.diff(
            before: beforeData, after: capture.png, tolerance: tolerance, scale: session.scale)
        let composite = try ImageOps.sideBySide(
            before: beforeData,
            after: capture.png,
            report: report,
            caption: "\(session.resolved ?? session.target) — \(report.summary)",
            scale: session.scale)
        try composite.write(to: compareURL(name), options: .atomic)
        try save(session)
        return ComparisonOutcome(session: session, report: report, composite: composite)
    }
}
