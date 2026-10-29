import Darwin
import Foundation

/// The app macOS charges this process's privacy grants to.
///
/// A command-line tool never holds Screen Recording or Accessibility itself.
/// TCC attributes it to the *responsible* process — the app the tool was
/// started from — and so does ScreenCaptureKit's own reminder alert. Measured
/// on macOS 27.0.1: `loupe record mac:Finder`, started by Claude Code's shell,
/// was granted through `com.anthropic.claude-code`, and the alert that went up
/// was keyed to that app's versioned bundle path, not to `loupe`. A remedy that
/// says "add loupe" sends the user to the wrong row.
///
/// No public API names the responsible process, so this walks the parent chain
/// to the nearest ancestor that is an app bundle — the process Launch Services
/// started, which is what TCC uses unless a launcher disclaimed it. A daemon
/// started by launchd has no such ancestor and is its own client. Best effort,
/// and labelled that way wherever it is shown.
public enum PrivacyAttribution {

    public struct Client: Sendable, Codable, Equatable {
        /// What the user looks for in System Settings, e.g. `Terminal`.
        public var name: String
        /// The `.app` bundle, or the bare executable when there is none.
        public var path: String
        /// True when nothing above this process is an app: the grant is its own.
        public var isSelf: Bool

        /// Who to turn on in System Settings, named the way the pane lists it.
        public var settingsEntry: String { isSelf ? path : "\(name) (\(path))" }

        public init(name: String, path: String, isSelf: Bool) {
            self.name = name
            self.path = path
            self.isSelf = isSelf
        }
    }

    /// The client for the running process, worked out once — the chain above a
    /// process does not change while it runs.
    public static let current: Client = attribute(chain: executableChain())

    /// Pick the client from executable paths, this process first.
    static func attribute(chain: [String]) -> Client {
        for path in chain {
            if let bundle = appBundle(containing: path) {
                return Client(
                    name: displayName(ofBundleAt: bundle), path: bundle,
                    isSelf: path == chain.first)
            }
        }
        let own = chain.first ?? CommandLine.arguments.first ?? "loupe"
        return Client(name: (own as NSString).lastPathComponent, path: own, isSelf: true)
    }

    /// `/Applications/Foo.app/Contents/MacOS/foo` → `/Applications/Foo.app`.
    ///
    /// The innermost bundle wins, unless it is a helper shipped in another
    /// app's `Contents/Frameworks` or `Contents/Helpers` — VS Code's
    /// `Code Helper.app`, Chrome's helpers inside its framework. TCC charges
    /// those to the main app, and System Settings has no row for the helper.
    /// An app elsewhere inside a bundle (Simulator.app in Xcode.app's
    /// `Contents/Developer/Applications`) is its own client.
    static func appBundle(containing path: String) -> String? {
        guard let range = path.range(of: ".app/Contents/MacOS/", options: .backwards) else {
            return nil
        }
        var bundle = String(path[..<range.lowerBound]) + ".app"
        while let outer = bundle.range(of: ".app/Contents/", options: .backwards) {
            let inside = bundle[outer.upperBound...]
            guard inside.hasPrefix("Frameworks/") || inside.hasPrefix("Helpers/") else { break }
            bundle = String(bundle[..<outer.lowerBound]) + ".app"
        }
        return bundle
    }

    private static func displayName(ofBundleAt path: String) -> String {
        let info = Bundle(path: path)?.infoDictionary
        let name =
            (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
        return name ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Executable paths from this process up to launchd.
    private static func executableChain() -> [String] {
        var chain: [String] = []
        var pid = getpid()
        // Bounded so a pathological chain cannot spin.
        for _ in 0..<32 where pid > 1 {
            if let path = executablePath(of: pid) { chain.append(path) }
            guard let parent = parentPID(of: pid), parent != pid else { break }
            pid = parent
        }
        return chain
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(
            bytes: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        return info.kp_eproc.e_ppid
    }
}
