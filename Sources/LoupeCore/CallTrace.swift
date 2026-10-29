import Foundation

/// What one tool call is doing right now, and a log line every time that changes.
///
/// Exists because "the call hung" is not something anyone can act on. A call
/// that runs out of time names the step it was stuck in — `xcrun simctl list
/// devices`, or reading one app's windows over Accessibility — and the same
/// steps land in a log file (``CallLog``), so a call whose client gave up first
/// still leaves the last step it reached behind.
///
/// Travels as a task-local, so the code that does the slow thing marks it
/// without every signature in between growing a parameter. Work hopped onto a
/// `DispatchQueue` loses it, so mark the step before the hop.
public final class CallTrace: @unchecked Sendable {

    /// The tool or verb, e.g. `loupe_list_targets`.
    public let call: String
    public let started = Date()
    private let number: Int

    private let lock = NSLock()
    /// Steps still under way, by token, so concurrent halves of one call (Mac
    /// apps and simulators) each show up instead of the later hiding the earlier.
    private var open: [Int: (step: String, since: Date)] = [:]
    private var nextToken = 0
    private var last: (step: String, since: Date)?

    @TaskLocal public static var active: CallTrace?

    private static let counter = LockedCounter()

    public init(call: String) {
        self.call = call
        self.number = Self.counter.next()
    }

    // MARK: - Marking steps

    /// Note that the current call has reached `step`. Free when no call is traced.
    public static func mark(_ step: @autoclosure () -> String) {
        active?.record(step())
    }

    /// Run `body` as `step`: while it runs, a timeout names it.
    public static func during<T>(
        _ step: @autoclosure () -> String, _ body: () async throws -> T
    ) async rethrows -> T {
        guard let trace = active else { return try await body() }
        let token = trace.begin(step())
        defer { trace.end(token) }
        return try await body()
    }

    /// The synchronous spelling of ``during(_:_:)``.
    public static func during<T>(_ step: @autoclosure () -> String, _ body: () throws -> T) rethrows -> T {
        guard let trace = active else { return try body() }
        let token = trace.begin(step())
        defer { trace.end(token) }
        return try body()
    }

    /// ``Deadline/run(seconds:_:_:)`` for one step of a traced call, marked
    /// as that step while it runs.
    public static func bounded<T: Sendable>(
        seconds: Double, _ step: String, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await Deadline.run(seconds: seconds, "\(step)") { try await during(step, body) }
    }

    // MARK: - Running a whole call

    /// Run one call traced, and — with `seconds` — give up on it after that long
    /// with an error naming the step it was stuck in.
    ///
    /// Giving up abandons the work rather than waiting for it (see ``Deadline``):
    /// the client gets an answer it can act on instead of sitting out its own,
    /// much longer, limit.
    public static func run<T: Sendable>(
        _ call: String, seconds: Double?, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let trace = CallTrace(call: call)
        trace.log("start")
        do {
            let value = try await Deadline.run(
                seconds: seconds ?? 0,
                timeoutError: {
                    let error = trace.timeoutError(after: seconds ?? 0)
                    trace.log("TIMED OUT: \(error.localizedDescription)")
                    return error
                },
                { try await $active.withValue(trace) { try await body() } })
            trace.log("done in \(trace.elapsed(since: trace.started))")
            return value
        } catch {
            if !(error is TimedOut) {
                trace.log("failed in \(trace.elapsed(since: trace.started)): \(error.localizedDescription)")
            }
            throw error
        }
    }

    /// What a call that ran out of time was doing: the steps still under way, or
    /// failing that the last one it reached.
    public var stuckIn: String {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let running = open.sorted { $0.key < $1.key }.map(\.value)
        if !running.isEmpty {
            return running.map { "\($0.step) (for \(Self.seconds(now.timeIntervalSince($0.since))))" }
                .joined(separator: "; ")
        }
        if let last { return "after \(last.step) (\(Self.seconds(now.timeIntervalSince(last.since))) ago)" }
        return "before its first step"
    }

    func timeoutError(after seconds: Double) -> TimedOut {
        TimedOut(
            message: "\(call) did not finish within \(Int(seconds))s; it was stuck in: \(stuckIn). "
                + "The call was abandoned so the next one is not blocked behind it. Each step is "
                + "logged to \(CallLog.shared.path ?? "(logging off)").")
    }

    /// A whole call ran out of time. Its own type so the failure is logged once.
    public struct TimedOut: Error, LocalizedError, CustomStringConvertible {
        public let message: String
        public var errorDescription: String? { message }
        public var description: String { message }
    }

    // MARK: - Bookkeeping

    private func record(_ step: String) {
        lock.lock()
        last = (step, Date())
        lock.unlock()
        log(step)
    }

    private func begin(_ step: String) -> Int {
        lock.lock()
        nextToken += 1
        let token = nextToken
        open[token] = (step, Date())
        last = (step, Date())
        lock.unlock()
        log(step)
        return token
    }

    private func end(_ token: Int) {
        lock.lock()
        let finished = open.removeValue(forKey: token)
        lock.unlock()
        // Only slow steps are worth a second line; the start is already logged.
        if let finished, Date().timeIntervalSince(finished.since) >= 1 {
            log("\(finished.step) took \(elapsed(since: finished.since))")
        }
    }

    private func elapsed(since date: Date) -> String { Self.seconds(Date().timeIntervalSince(date)) }

    private static func seconds(_ interval: TimeInterval) -> String { String(format: "%.1fs", interval) }

    private func log(_ text: String) {
        CallLog.shared.write("#\(number) \(call): \(text)")
    }
}

/// The append-only file ``CallTrace`` writes to.
///
/// `~/Library/Logs/Loupe/calls.log` unless `LOUPE_CALL_LOG` names another file;
/// `LOUPE_CALL_LOG=off` turns it off. Every line carries the pid, because
/// several Loupe processes on one Mac share the file — which is the point when
/// one of them hangs while another works. Lines are single `O_APPEND` writes, so
/// processes do not interleave inside a line. Rolled over to `calls.log.1` past
/// 2 MB when a process first opens it.
public final class CallLog: @unchecked Sendable {

    public static let shared = CallLog(environment: ProcessInfo.processInfo.environment)

    /// Where lines go, nil when logging is off or the file cannot be opened.
    public let path: String?
    private let handle: FileHandle?
    private let lock = NSLock()
    private let pid = ProcessInfo.processInfo.processIdentifier
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(environment: [String: String]) {
        let configured = environment["LOUPE_CALL_LOG"]?.trimmingCharacters(in: .whitespaces)
        if let configured, ["off", "0", "false", "none"].contains(configured.lowercased()) {
            path = nil
            handle = nil
            return
        }
        let target: String
        if let configured, !configured.isEmpty {
            target = (configured as NSString).expandingTildeInPath
        } else {
            target = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/Loupe/calls.log").path
        }
        handle = Self.open(target)
        path = handle == nil ? nil : target
    }

    private static func open(_ path: String) -> FileHandle? {
        let manager = FileManager.default
        try? manager.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: path))?[.size] as? NSNumber,
            size.intValue > 2_000_000 {
            try? manager.removeItem(atPath: path + ".1")
            try? manager.moveItem(atPath: path, toPath: path + ".1")
        }
        let descriptor = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return nil }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    public func write(_ text: String) {
        guard let handle else { return }
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) pid=\(pid) \(text)\n"
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
