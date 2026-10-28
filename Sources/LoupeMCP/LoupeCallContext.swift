import Foundation

/// What a host knows about one tool call that the call's own arguments do not say.
///
/// A host that runs several agents through one Loupe scopes each call to its run:
/// relative paths mean something different per run, and artifacts belong with the
/// run that produced them. Travels as a task-local so it reaches the tool bodies
/// without widening every tool's signature (which is the schema agents see).
/// Cancelling the task that awaits the call cancels the call; there is nothing
/// extra to wire for that.
public struct LoupeCallContext: Sendable {

    /// Base for relative paths a call names, such as `loupe_script`'s `path`.
    public var workingDirectory: URL?

    /// Where artifacts the caller did not place go, such as a script's screenshots.
    /// An explicit argument on the call still wins.
    public var evidenceDirectory: URL?

    public init(workingDirectory: URL? = nil, evidenceDirectory: URL? = nil) {
        self.workingDirectory = workingDirectory
        self.evidenceDirectory = evidenceDirectory
    }

    @TaskLocal static var current = LoupeCallContext()

    /// Run `body` with this context in effect for every tool call inside it.
    public func perform<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        try await Self.$current.withValue(self, operation: body)
    }

    /// A path from a call, made absolute against the working directory when it has
    /// one and is relative. `~` is expanded first, as everywhere else in Loupe.
    static func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if !expanded.hasPrefix("/"), let base = current.workingDirectory {
            return URL(fileURLWithPath: expanded, relativeTo: base).standardizedFileURL
        }
        return URL(fileURLWithPath: expanded)
    }
}
