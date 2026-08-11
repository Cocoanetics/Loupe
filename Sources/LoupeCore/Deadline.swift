import Foundation

/// Run `body`, or stop waiting for it.
///
/// Deliberately not a `TaskGroup`: a group waits for every child before it
/// returns, so racing an uncancellable call against a sleep still hangs — which
/// is the exact shape of the failures this exists for. ScreenCaptureKit can
/// accept a request and never call back, and an accessibility walk of a large
/// window can outlive anyone's patience; neither notices cancellation. So the
/// loser is abandoned rather than awaited.
///
/// Abandoning a task is a real cost, and the alternative is worse: without this
/// a `loupe capture mac:…` that hits the ScreenCaptureKit stall sits there
/// forever with no error, no output, and nothing to act on.
public enum Deadline {

    public static func run<T: Sendable>(
        seconds: Double,
        _ what: @autoclosure @Sendable () -> String,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // `isFinite` as well as `> 0`: an infinite or absurd deadline would
        // otherwise overflow the nanosecond conversion and trap.
        guard seconds > 0, seconds.isFinite else { return try await body() }
        let gate = Gate<T>()
        Task.detached {
            do { gate.finish(.success(try await body())) } catch { gate.finish(.failure(error)) }
        }
        let description = what()
        Task.detached {
            let nanoseconds = (seconds * 1_000_000_000).rounded()
            try? await Task.sleep(
                nanoseconds: nanoseconds < Double(UInt64.max) ? UInt64(nanoseconds) : .max)
            gate.finish(
                .failure(
                    LoupeError.failed(
                        "\(description) did not answer within \(Int(seconds))s. It was abandoned "
                            + "rather than waited on, so nothing is stuck — but nothing was read "
                            + "either. Retry, and if it repeats the app is not answering.")))
        }
        return try await withCheckedThrowingContinuation { gate.attach($0) }
    }
}

/// Carries a non-`Sendable` value across the one task boundary `Deadline.run`
/// introduces.
///
/// Justified narrowly: the value is produced by the body, crosses once, and is
/// then used only by the caller — it is never shared between the two tasks, and
/// the abandoned task cannot touch it because it never receives it. Anything
/// with wider reach should not use this.
public struct Unchecked<Value>: @unchecked Sendable {
    public let value: Value
    public init(_ value: Value) { self.value = value }
}

/// Whichever of the two tasks finishes first wins; the other's result is dropped.
///
/// Hand-rolled rather than an actor because the continuation may be attached
/// after the winner has already finished, and that ordering has to be handled
/// synchronously or the result is lost and the caller waits forever.
private final class Gate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var pending: Result<T, any Error>?
    private var done = false

    func attach(_ continuation: CheckedContinuation<T, any Error>) {
        lock.lock()
        if let pending {
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<T, any Error>) {
        lock.lock()
        guard !done else { return lock.unlock() }
        done = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pending = result
            lock.unlock()
        }
    }
}
