import Foundation
import LoupeCore

extension Bridge {

    /// Get a live bridge for a device, reusing one if it is already answering.
    ///
    /// Three costs, in increasing order and each paid at most once: building the
    /// runner (~8 s, ever, cached in `~/.loupe/bridge`), installing it on a
    /// device (~0.5 s, once per device), and starting a session (~3 s warm).
    /// A second `loupe` invocation against the same device pays none of them.
    static func live(for udid: String) async throws -> Bridge {
        if let existing = try? load(udid) {
            let bridge = Bridge(udid: udid, port: existing.port, token: existing.token)
            if (try? await bridge.health()) != nil {
                if let app = existing.app { _ = try? await bridge.attach(bundleID: app, restart: false) }
                return bridge
            }
            // Recorded but not answering: the runner died or the device rebooted.
            remove(udid)
        }
        let app = try await runnerApp(for: udid)
        try await install(app, on: udid)
        return try await start(on: udid)
    }

    // MARK: - Building

    /// The prebuilt runner, built on first use and then cached.
    ///
    /// Builds into a scratch directory under the system temporary directory
    /// rather than the machine's DerivedData: the product's location is then
    /// known exactly, instead of being recovered from `-showBuildSettings`,
    /// which cannot resolve a destination for a scheme that has no app target.
    /// Only the finished `.app` is kept, in `~/.loupe/bridge`.
    static func runnerApp(for udid: String) async throws -> URL {
        let cached = root.appendingPathComponent("LoupeBridgeUITests-Runner.app")
        if FileManager.default.fileExists(atPath: cached.path) { return cached }

        guard let project = projectURL() else {
            throw LoupeError.failed(
                "cannot find the bridge Xcode project — expected Bridge/LoupeBridge.xcodeproj "
                    + "beside the Loupe package")
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-bridge-build", isDirectory: true)
        let build = try await runTool(
            "xcodebuild",
            [
                "build-for-testing",
                "-project", project.path,
                "-scheme", "LoupeBridge",
                "-destination", "platform=iOS Simulator,id=\(udid)",
                "-derivedDataPath", scratch.path,
                "-quiet"
            ], timeout: 900)
        let product = scratch
            .appendingPathComponent("Build/Products/Debug-iphonesimulator")
            .appendingPathComponent("LoupeBridgeUITests-Runner.app")
        guard FileManager.default.fileExists(atPath: product.path) else {
            throw LoupeError.failed(
                "could not build the simulator bridge (exit \(build.status)):\n"
                    + (build.err.isEmpty ? build.out : build.err))
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: cached)
        try FileManager.default.copyItem(at: product, to: cached)
        // The scratch build is deliberately kept: the xcodebuild fallback needs
        // the .xctestrun it produced, and that file points back into this tree.
        // If it is cleaned up later, the next run just rebuilds.
        return cached
    }

    /// Walk up from this source file to find the package, so the project is
    /// found whether Loupe runs from a checkout or an installed binary.
    private static func projectURL() -> URL? {
        var candidates: [URL] = []
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(directory.appendingPathComponent("Bridge/LoupeBridge.xcodeproj"))
            directory = directory.deletingLastPathComponent()
        }
        candidates.append(root.appendingPathComponent("LoupeBridge.xcodeproj"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Run a developer tool through `xcrun`. `Simctl` only speaks simctl, and
    /// building the runner needs xcodebuild.
    /// What a tool run produced. A named type rather than a tuple: the two
    /// string fields are indistinguishable at the use site otherwise.
    struct ToolOutput: Sendable {
        var status: Int32
        var out: String
        var err: String
    }

    private static func runTool(
        _ tool: String, _ arguments: [String], timeout: Double
    ) async throws -> ToolOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                process.arguments = [tool] + arguments
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // Drain both pipes before waiting: xcodebuild produces far more
                // than a pipe buffer holds, and a full buffer deadlocks it.
                let out = output.fileHandleForReading.readDataToEndOfFile()
                let err = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(
                    returning: ToolOutput(
                        status: process.terminationStatus,
                        out: String(bytes: out, encoding: .utf8) ?? "",
                        err: String(bytes: err, encoding: .utf8) ?? ""))
            }
        }
    }

    // MARK: - Installing and starting

    private static func install(_ app: URL, on udid: String) async throws {
        let result = try await Simctl.run(["install", udid, app.path], timeout: 120)
        guard result.status == 0 else {
            throw LoupeError.failed("could not install the bridge runner:\n\(result.diagnostics)")
        }
    }

    private static func start(on udid: String) async throws -> Bridge {
        // Launching an app that is already running re-focuses it and ignores the
        // new environment, so a stale runner would keep its old port and the
        // wait below would time out with everything apparently fine.
        _ = try? await Simctl.run(["terminate", udid, bundleID], timeout: 20)

        let port = try freePort()
        let token = UUID().uuidString
        let platform =
            "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform"

        // XCTRunner bootstraps itself given these two paths — no serialized
        // XCTestConfiguration, no testmanagerd handshake, no xcodebuild. The
        // `-XCTest` selector matters: without it the whole bundle runs
        // alphabetically, which costs several seconds for nothing.
        let environment = [
            "SIMCTL_CHILD_DYLD_FRAMEWORK_PATH": "\(platform)/Developer/Library/Frameworks",
            "SIMCTL_CHILD_DYLD_LIBRARY_PATH": "\(platform)/Developer/usr/lib",
            "SIMCTL_CHILD_LOUPE_BRIDGE_PORT": "\(port)",
            "SIMCTL_CHILD_LOUPE_BRIDGE_TOKEN": token
        ]
        let launch = try await Simctl.run(
            [
                "launch", udid, bundleID, "-XCTest", "BridgeServer/testServe",
                // Passed as arguments, not only as SIMCTL_CHILD_ environment:
                // the environment does not reach the test process on iPad
                // simulators, where the runner then skipped in silence.
                "-loupePort", "\(port)", "-loupeToken", token
            ],
            timeout: 120, environment: environment)
        guard launch.status == 0 else {
            throw LoupeError.failed("could not start the bridge runner:\n\(launch.diagnostics)")
        }

        let bridge = Bridge(udid: udid, port: port, token: token)
        if try await bridge.answers(within: 20) {
            try save(Descriptor(udid: udid, port: port, token: token, startedAt: Date()))
            return bridge
        }

        // The self-bootstrap works on iPhone simulators but not on iPad ones,
        // where XCTest connects and then never runs the test. Rather than
        // reporting a timeout, fall back to the supported path: xcodebuild
        // starts the same bundle, reaches the same bridge, and costs a few
        // seconds and one extra process.
        try await startViaXcodebuild(on: udid, port: port, token: token)
        if try await bridge.answers(within: 90) {
            try save(Descriptor(udid: udid, port: port, token: token, startedAt: Date()))
            return bridge
        }
        throw LoupeError.timeout(
            "the simulator bridge did not answer on port \(port). Neither launching the runner "
                + "directly nor `xcodebuild test-without-building` brought it up.")
    }

    /// Start the runner the supported way, in the background: this process never
    /// ends, so waiting for xcodebuild to exit would wait forever.
    private static func startViaXcodebuild(
        on udid: String, port: UInt16, token: String
    ) async throws {
        guard let testRun = xctestrunURL() else {
            throw LoupeError.failed(
                "the bridge runner could not be started, and no .xctestrun was found to retry "
                    + "with. Remove ~/.loupe/bridge to force a rebuild.")
        }
        // xcodebuild does not forward this process's environment to the test, so
        // the port and token have to be written into the .xctestrun itself.
        let patched = try patch(testRun, port: port, token: token)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xcodebuild", "test-without-building",
            "-xctestrun", patched.path,
            "-destination", "platform=iOS Simulator,id=\(udid)",
            "-only-testing:LoupeBridgeUITests/BridgeServer/testServe"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Write the bridge's port and token into a copy of the test plan, since
    /// that is the only channel xcodebuild offers into the test process.
    private static func patch(_ testRun: URL, port: UInt16, token: String) throws -> URL {
        let data = try Data(contentsOf: testRun)
        guard var plan = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any]
        else { throw LoupeError.failed("could not read \(testRun.lastPathComponent)") }

        let variables = ["LOUPE_BRIDGE_PORT": "\(port)", "LOUPE_BRIDGE_TOKEN": token]
        for (key, value) in plan {
            guard key != "__xctestrun_metadata__", var target = value as? [String: Any] else {
                continue
            }
            var environment = target["EnvironmentVariables"] as? [String: String] ?? [:]
            environment.merge(variables) { _, new in new }
            target["EnvironmentVariables"] = environment
            var testing = target["TestingEnvironmentVariables"] as? [String: String] ?? [:]
            testing.merge(variables) { _, new in new }
            target["TestingEnvironmentVariables"] = testing
            plan[key] = target
        }

        let patched = testRun.deletingLastPathComponent()
            .appendingPathComponent("loupe-bridge-session.xctestrun")
        let output = try PropertyListSerialization.data(
            fromPropertyList: plan, format: .xml, options: 0)
        try output.write(to: patched, options: .atomic)
        return patched
    }

    private static func xctestrunURL() -> URL? {
        let products = FileManager.default.temporaryDirectory
            .appendingPathComponent("loupe-bridge-build/Build/Products", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: products, includingPropertiesForKeys: nil)) ?? []
        return entries.first { $0.pathExtension == "xctestrun" }
    }

    /// Ask the kernel for a port rather than picking one, so two devices driven
    /// at once never collide.
    private static func freePort() throws -> UInt16 {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { throw LoupeError.failed("could not open a socket") }
        defer { close(handle) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw LoupeError.failed("could not reserve a port") }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &length)
            }
        }
        guard named == 0 else { throw LoupeError.failed("could not read the reserved port") }
        return UInt16(bigEndian: assigned.sin_port)
    }

    // MARK: - Registry

    private static func descriptorURL(_ udid: String) -> URL {
        root.appendingPathComponent("\(udid).json")
    }

    static func load(_ udid: String) throws -> Descriptor {
        let data = try Data(contentsOf: descriptorURL(udid))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Descriptor.self, from: data)
    }

    static func save(_ descriptor: Descriptor) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(descriptor).write(to: descriptorURL(descriptor.udid), options: .atomic)
    }

    /// Remember which app this device is being driven against.
    static func rememberApp(_ bundleID: String, on udid: String) {
        guard var descriptor = try? load(udid) else { return }
        descriptor.app = bundleID
        try? save(descriptor)
    }

    static func remove(_ udid: String) {
        try? FileManager.default.removeItem(at: descriptorURL(udid))
    }
}
