import Foundation
import LoupeCore

// MARK: - Devices

/// One simulator device, as reported by `simctl list devices --json`.
public struct SimulatorDevice: Codable, Hashable, Sendable, CustomStringConvertible {
    public var udid: String
    public var name: String
    /// CoreSimulator's own wording: `Booted`, `Shutdown`, `Booting`,
    /// `Shutting Down`, `Creating`. Kept verbatim rather than mapped to an enum so
    /// a new state in a future Xcode surfaces instead of being swallowed.
    public var state: String
    /// Pretty runtime name derived from the runtime identifier, e.g. `iOS 26.2`.
    public var runtime: String
    /// The runtime identifier the device was listed under, e.g.
    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-2`.
    public var runtimeIdentifier: String
    /// e.g. `com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro`. Optional because
    /// a device whose device type has been removed still lists.
    public var deviceTypeIdentifier: String?
    /// False for devices whose runtime is no longer installed. Those cannot boot.
    public var isAvailable: Bool

    public init(
        udid: String,
        name: String,
        state: String,
        runtime: String,
        runtimeIdentifier: String,
        deviceTypeIdentifier: String? = nil,
        isAvailable: Bool = true
    ) {
        self.udid = udid
        self.name = name
        self.state = state
        self.runtime = runtime
        self.runtimeIdentifier = runtimeIdentifier
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.isAvailable = isAvailable
    }

    public var isBooted: Bool { state == "Booted" }

    public var description: String { "\(name) (\(runtime), \(state), \(udid))" }
}

/// Physical screen numbers for a device type.
struct SimulatorScreenMetrics: Sendable {
    var pixelWidth: Int
    var pixelHeight: Int
    /// Backing scale: 3.0 on most iPhones, 2.0 on iPads and the small iPhones.
    var scale: Double
}

/// A device type as listed by `simctl list devicetypes --json`, reduced to the
/// two fields we need: where its profile bundle lives, and what family it is.
struct SimulatorDeviceType: Sendable {
    var identifier: String
    var bundlePath: String
    var productFamily: String?
}

// MARK: - Process wrapper

/// Everything Loupe knows about talking to `xcrun simctl`.
///
/// One funnel means one place that knows how to spawn the tool, keep stdout and
/// stderr apart, and turn a non-zero exit into a ``LoupeError`` that carries the
/// stderr text — which is where simctl puts everything worth reading. Arguments
/// are always an array, never a shell string, so a device name with spaces or a
/// deep link with `&` in it cannot be reinterpreted as shell syntax.
enum Simctl {
    /// `xcrun` rather than a hardcoded path into Xcode.app: it resolves the
    /// *active* developer directory, so `xcode-select` is honored without Loupe
    /// caching a stale toolchain location.
    private static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")

    /// `Process` is blocking, and a wedged simulator must not take a Swift
    /// concurrency thread down with it — so every invocation hops onto this queue
    /// instead of stalling the cooperative pool. Concurrent because independent
    /// simctl calls (and the two pipe readers below) genuinely are independent.
    private static let queue = DispatchQueue(
        label: "com.cocoanetics.loupe.simctl", qos: .userInitiated, attributes: .concurrent)

    struct Output: Sendable {
        var status: Int32
        var out: String
        var err: String

        var succeeded: Bool { status == 0 }

        /// Whichever stream actually said something, preferring stderr.
        var diagnostics: String {
            if !err.isEmpty { return err }
            if !out.isEmpty { return out }
            return "(no output)"
        }
    }

    /// Runs simctl and returns its result, successful or not.
    ///
    /// - Parameter environment: extra variables layered on top of the inherited
    ///   environment. Used for `SIMCTL_CHILD_*`, which is how simctl passes values
    ///   through to a launched app.
    static func run(
        _ args: [String], timeout: Double = 120, environment: [String: String] = [:]
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(
                    with: Result { try runBlocking(args, timeout: timeout, environment: environment) })
            }
        }
    }

    /// Runs simctl and throws unless it exited zero.
    @discardableResult
    static func check(
        _ args: [String], timeout: Double = 120, environment: [String: String] = [:]
    ) async throws -> Output {
        let output = try await run(args, timeout: timeout, environment: environment)
        guard output.succeeded else {
            throw LoupeError.failed(failureMessage(args: args, output: output))
        }
        return output
    }

    static func failureMessage(args: [String], output: Output) -> String {
        "`xcrun simctl \(args.joined(separator: " "))` failed (exit \(output.status)):\n\(output.diagnostics)"
    }

    private static func runBlocking(
        _ args: [String], timeout: Double, environment: [String: String]
    ) throws -> Output {
        let process = Process()
        process.executableURL = xcrun
        process.arguments = ["simctl"] + args
        // The caller's environment is inherited on purpose: that is exactly how
        // `SIMCTL_CHILD_*` variables already exported in the shell reach an app
        // started by `simctl launch`. Per-call additions are layered on top.
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in
                new
            }
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            throw LoupeError.failed(
                "could not run `/usr/bin/xcrun simctl`: \(error.localizedDescription)\n"
                    + "  Fix: install Xcode command line tools and check `xcode-select -p`.")
        }

        // Drain both pipes on their own threads *before* waiting for exit.
        // `simctl list devices --json` is well past the 64 KB pipe buffer, so
        // waiting first and reading second would deadlock on a busy Mac.
        let outBytes = Locked(Data())
        let errBytes = Locked(Data())
        let readers = DispatchGroup()
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        queue.async(group: readers) { outBytes.value = (try? outHandle.readToEnd()) ?? Data() }
        queue.async(group: readers) { errBytes.value = (try? errHandle.readToEnd()) ?? Data() }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 5)
            readers.wait()
            throw LoupeError.timeout(
                "`xcrun simctl \(args.joined(separator: " "))` did not finish within \(Int(timeout))s")
        }
        readers.wait()

        return Output(
            status: process.terminationStatus,
            out: text(outBytes.value),
            err: text(errBytes.value))
    }

    /// Decoding that cannot fail, on purpose.
    ///
    /// This is a subprocess's diagnostics, and it is read precisely when
    /// something has gone wrong. One byte of stray encoding in a device name must
    /// not turn a useful error message into `nil` — a replacement character in
    /// the middle of it costs the reader nothing.
    private static func text(_ data: Data) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Queries

    /// Every device CoreSimulator knows about, across all runtimes.
    ///
    /// - Parameter matching: optional simctl search term (a udid or a name).
    ///   Narrowing matters for polling loops: the unfiltered listing on a
    ///   developer's Mac is ~100 KB of JSON to parse every half second.
    static func devices(matching search: String? = nil) async throws -> [SimulatorDevice] {
        var args = ["list", "devices"]
        if let search { args.append(search) }
        args.append("--json")
        let output = try await check(args)
        guard let data = output.out.data(using: .utf8) else {
            throw LoupeError.failed("`xcrun simctl \(args.joined(separator: " "))` produced no output")
        }
        let payload: DeviceListPayload
        do {
            payload = try JSONDecoder().decode(DeviceListPayload.self, from: data)
        } catch {
            throw LoupeError.failed(
                "could not parse `simctl list devices --json`: \(error.localizedDescription)")
        }
        return payload.devices.flatMap { runtimeIdentifier, entries in
            entries.map { entry in
                SimulatorDevice(
                    udid: entry.udid,
                    name: entry.name,
                    state: entry.state,
                    runtime: runtimeName(fromIdentifier: runtimeIdentifier),
                    runtimeIdentifier: runtimeIdentifier,
                    deviceTypeIdentifier: entry.deviceTypeIdentifier,
                    isAvailable: entry.isAvailable ?? true)
            }
        }
        .sorted { ($0.runtime, $0.name) < ($1.runtime, $1.name) }
    }

    /// Looks up one device type so we can find its profile bundle on disk.
    static func deviceType(identifier: String) async throws -> SimulatorDeviceType? {
        let output = try await check(["list", "devicetypes", "--json"])
        guard let data = output.out.data(using: .utf8),
            let payload = try? JSONDecoder().decode(DeviceTypeListPayload.self, from: data)
        else { return nil }
        guard let entry = payload.devicetypes.first(where: { $0.identifier == identifier }) else {
            return nil
        }
        return SimulatorDeviceType(
            identifier: entry.identifier,
            bundlePath: entry.bundlePath,
            productFamily: entry.productFamily)
    }

    /// Reads the real screen numbers out of a device type's profile bundle.
    ///
    /// This is the only *measured* source of the backing scale that public tooling
    /// offers. `simctl io … enumerate` reports the framebuffer in pixels — the same
    /// number a screenshot already gives us — and the device-type JSON carries no
    /// screen fields at all, so neither can tell points from pixels. The bundle's
    /// `capabilities.plist` has `ScreenDimensionsCapability`, which is where
    /// CoreSimulator itself gets `main-screen-scale`.
    static func screenMetrics(deviceTypeBundlePath: String) -> SimulatorScreenMetrics? {
        let url = URL(fileURLWithPath: deviceTypeBundlePath)
            .appendingPathComponent("Contents/Resources/capabilities.plist")
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let root = plist as? [String: Any],
            let capabilities = root["capabilities"] as? [String: Any],
            let dimensions = capabilities["ScreenDimensionsCapability"] as? [String: Any],
            let width = (dimensions["main-screen-width"] as? NSNumber)?.intValue,
            let height = (dimensions["main-screen-height"] as? NSNumber)?.intValue,
            let scale = (dimensions["main-screen-scale"] as? NSNumber)?.doubleValue,
            width > 0, height > 0, scale > 0
        else { return nil }
        return SimulatorScreenMetrics(pixelWidth: width, pixelHeight: height, scale: scale)
    }

    /// `CFBundleIdentifier` of a built `.app`, so `launch` can take a path.
    static func bundleIdentifier(atAppPath path: String) throws -> String {
        let plistURL = URL(fileURLWithPath: path).appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL) else {
            throw LoupeError.failed("no Info.plist inside \(path) — is that really an app bundle?")
        }
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let root = plist as? [String: Any],
            let identifier = root["CFBundleIdentifier"] as? String,
            !identifier.isEmpty
        else {
            throw LoupeError.failed("could not read CFBundleIdentifier from \(plistURL.path)")
        }
        return identifier
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-2` → `iOS 26.2`.
    static func runtimeName(fromIdentifier identifier: String) -> String {
        guard let tail = identifier.split(separator: ".").last else { return identifier }
        let parts = tail.split(separator: "-")
        guard parts.count >= 2 else { return String(tail) }
        return String(parts[0]) + " " + parts.dropFirst().joined(separator: ".")
    }

}

// MARK: - JSON shapes

/// `simctl list devices --json`: devices keyed by runtime identifier.
private struct DeviceListPayload: Decodable {
    struct Entry: Decodable {
        var udid: String
        var name: String
        var state: String
        var isAvailable: Bool?
        var deviceTypeIdentifier: String?
    }
    var devices: [String: [Entry]]
}

/// `simctl list devicetypes --json`, reduced to the fields Loupe reads.
private struct DeviceTypeListPayload: Decodable {
    struct Entry: Decodable {
        var identifier: String
        var bundlePath: String
        var productFamily: String?
    }
    var devicetypes: [Entry]
}

// MARK: - Locked

/// The smallest possible mutable-shared-state box.
///
/// ``SimDriver`` is a `Sendable` class whose resolved-device cache is written by
/// async work but read from the *synchronous* ``UIDriver/targetDescription``
/// property, so an actor does not fit. A lock does, and it is also what lets the
/// two pipe-reader threads above hand their bytes back.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&storage)
    }
}
