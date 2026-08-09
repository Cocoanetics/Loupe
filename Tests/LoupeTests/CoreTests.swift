import CoreGraphics
import Foundation
import Testing

@testable import LoupeCore

@Suite("Target parsing")
struct TargetTests {

    @Test("bare URLs imply the web surface")
    func bareURL() throws {
        let target = try Target.parse("https://example.com/a?b=c")
        #expect(target.surface == .web)
        #expect(target.locator == "https://example.com/a?b=c")
    }

    @Test("explicit schemes")
    func schemes() throws {
        #expect(try Target.parse("web:https://x.dev").surface == .web)
        #expect(try Target.parse("mac:Safari").surface == .mac)
        #expect(try Target.parse("sim:booted").surface == .sim)
    }

    @Test("mac window index")
    func windowIndex() throws {
        let target = try Target.parse("mac:Safari#2")
        #expect(target.locator == "Safari")
        #expect(target.windowIndex == 2)
    }

    @Test("a URL fragment is not a window index")
    func fragmentIsNotWindowIndex() throws {
        // `#` only means "window" for mac targets; a web fragment must survive.
        let target = try Target.parse("web:https://example.com#section")
        #expect(target.locator == "https://example.com#section")
        #expect(target.windowIndex == nil)
    }

    @Test("device names with spaces and udids")
    func simLocators() throws {
        #expect(try Target.parse("sim:iPhone 17 Pro").locator == "iPhone 17 Pro")
        #expect(
            try Target.parse("sim:6805ED2E-71F6-4BF1-A104-5F76C340A250").locator
                == "6805ED2E-71F6-4BF1-A104-5F76C340A250")
    }

    @Test("round-trips through its description")
    func roundTrip() throws {
        for raw in ["web:https://x.dev", "mac:Safari", "mac:Safari#3", "sim:booted"] {
            #expect(try Target.parse(raw).description == raw)
        }
    }

    @Test("rejects nonsense")
    func rejects() {
        #expect(throws: LoupeError.self) { try Target.parse("") }
        #expect(throws: LoupeError.self) { try Target.parse("ftp:whatever") }
        #expect(throws: LoupeError.self) { try Target.parse("mac:") }
    }
}

@Suite("Image diffing")
struct ImageOpsTests {

    /// A differently-colored rectangle drawn into a test image.
    struct Patch {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    /// Solid-color PNG of a given size, with an optional differently-colored rect.
    static func png(
        width: Int, height: Int, gray: Double = 0.5,
        patch: Patch? = nil, patchGray: Double = 1.0
    ) throws -> Data {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let patch {
            ctx.setFillColor(CGColor(red: patchGray, green: patchGray, blue: patchGray, alpha: 1))
            ctx.fill(CGRect(x: patch.x, y: patch.y, width: patch.width, height: patch.height))
        }
        return try ImageOps.encode(ctx.makeImage()!)
    }

    @Test("identical images report no difference")
    func identical() throws {
        let image = try Self.png(width: 200, height: 120)
        let report = try ImageOps.diff(before: image, after: image)
        #expect(!report.isDifferent)
        #expect(report.changedFraction == 0)
        #expect(report.maxChannelDelta == 0)
    }

    @Test("sub-tolerance noise is not a difference")
    func toleranceAbsorbsDithering() throws {
        // The measured real-world case: two renders of the same page differing by
        // <=3/255 on most pixels. A byte comparison would call this a change.
        let before = try Self.png(width: 200, height: 120, gray: 0.5)
        let after = try Self.png(width: 200, height: 120, gray: 0.5 + 3.0 / 255.0)
        let report = try ImageOps.diff(before: before, after: after)
        #expect(report.maxChannelDelta <= ImageOps.defaultTolerance)
        #expect(!report.isDifferent)
    }

    @Test("a real change is caught and localized")
    func realChange() throws {
        let before = try Self.png(width: 200, height: 120, gray: 0.2)
        let after = try Self.png(
            width: 200, height: 120, gray: 0.2,
            patch: Patch(x: 40, y: 30, width: 64, height: 32), patchGray: 0.9)
        let report = try ImageOps.diff(before: before, after: after)
        #expect(report.isDifferent)
        #expect(report.maxChannelDelta > 100)
        #expect(!report.regions.isEmpty)

        // The reported region should cover the patch we drew. CoreGraphics is
        // bottom-left origin while regions are top-left, so check size not origin.
        let region = report.regions[0]
        #expect(region.width >= 64)
        #expect(region.height >= 32)
    }

    @Test("size changes are reported rather than crashing")
    func sizeChange() throws {
        let before = try Self.png(width: 200, height: 120)
        let after = try Self.png(width: 240, height: 120)
        let report = try ImageOps.diff(before: before, after: after)
        #expect(report.sizeChanged)
        #expect(report.isDifferent)
        #expect(report.summary.contains("size changed"))
    }

    @Test("side-by-side composition produces a wider image")
    func composition() throws {
        let before = try Self.png(width: 200, height: 120, gray: 0.2)
        let after = try Self.png(
            width: 200, height: 120, gray: 0.2, patch: Patch(x: 10, y: 10, width: 40, height: 40))
        let report = try ImageOps.diff(before: before, after: after)
        let composite = try ImageOps.sideBySide(
            before: before, after: after, report: report, caption: "test")
        let image = try ImageOps.decode(composite)
        #expect(image.width > 400)  // two panels plus gutters
        #expect(image.height > 120)  // plus header and caption
    }

    @Test("fit downscales only when needed")
    func fit() throws {
        let big = try Self.png(width: 2000, height: 1000)
        let shrunk = try ImageOps.fit(big, maxEdge: 500)
        #expect(try ImageOps.decode(shrunk).width == 500)

        let small = try Self.png(width: 100, height: 50)
        #expect(try ImageOps.fit(small, maxEdge: 500) == small)
    }
}

@Suite("Comparison sessions")
struct ComparisonTests {

    static func makeStore() -> (ComparisonStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("loupe-tests-\(UUID().uuidString)", isDirectory: true)
        return (ComparisonStore(root: dir), dir)
    }

    @Test("before then after produces a report and a composite")
    func roundTrip() throws {
        let (store, dir) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let before = Capture(
            png: try ImageOpsTests.png(width: 120, height: 80, gray: 0.3),
            pointSize: CGSize(width: 120, height: 80), scale: 1, target: "web:https://x.dev")
        try store.recordBefore(name: "issue-517", capture: before, target: "web:https://x.dev")

        let after = Capture(
            png: try ImageOpsTests.png(
                width: 120, height: 80, gray: 0.3,
                patch: ImageOpsTests.Patch(x: 20, y: 20, width: 40, height: 20)),
            pointSize: CGSize(width: 120, height: 80), scale: 1, target: "web:https://x.dev")
        let outcome = try store.recordAfter(name: "issue-517", capture: after)

        #expect(outcome.session.beforeAt != nil)
        #expect(outcome.session.afterAt != nil)
        #expect(outcome.report.isDifferent)
        #expect(!outcome.composite.isEmpty)
        #expect(FileManager.default.fileExists(atPath: store.compareURL("issue-517").path))
    }

    @Test("after without before fails loudly")
    func afterWithoutBefore() throws {
        let (store, dir) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = Capture(
            png: try ImageOpsTests.png(width: 10, height: 10),
            pointSize: CGSize(width: 10, height: 10), scale: 1, target: "t")
        #expect(throws: LoupeError.self) {
            _ = try store.recordAfter(name: "never-started", capture: capture)
        }
    }

    @Test("re-recording before invalidates a stale after")
    func rerecordBefore() throws {
        let (store, dir) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shot = Capture(
            png: try ImageOpsTests.png(width: 10, height: 10),
            pointSize: CGSize(width: 10, height: 10), scale: 1, target: "t")
        try store.recordBefore(name: "s", capture: shot, target: "web:https://x.dev")
        _ = try store.recordAfter(name: "s", capture: shot)
        #expect(FileManager.default.fileExists(atPath: store.afterURL("s").path))

        // A second round of the same fix must not silently compare against the
        // previous round's "after".
        try store.recordBefore(name: "s", capture: shot, target: "web:https://x.dev")
        #expect(!FileManager.default.fileExists(atPath: store.afterURL("s").path))
        #expect(try store.load("s")?.afterAt == nil)
    }

    @Test("the session stores the target as written, not the driver's description")
    func targetRoundTrips() throws {
        let (store, dir) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Drivers report something human-readable that is NOT re-parseable, and
        // whose pid is meaningless after a relaunch. `after` has to be able to
        // resolve the target in a later process, so the two must stay separate.
        let shot = Capture(
            png: try ImageOpsTests.png(width: 10, height: 10),
            pointSize: CGSize(width: 10, height: 10), scale: 1,
            target: "mac:TextEdit#0 'note.txt' (pid 71894)")
        try store.recordBefore(name: "round-trip", capture: shot, target: "mac:TextEdit")

        let session = try #require(try store.load("round-trip"))
        #expect(session.target == "mac:TextEdit")
        #expect(session.resolved == "mac:TextEdit#0 'note.txt' (pid 71894)")
        #expect(try Target.parse(session.target).locator == "TextEdit")
    }

    @Test(
        "session names cannot escape the store",
        arguments: ["../../etc/passwd", "..", ".", "/etc/passwd", "a/b/c", "", "  "])
    func sanitizes(name: String) throws {
        let (store, dir) = Self.makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shot = Capture(
            png: try ImageOpsTests.png(width: 10, height: 10),
            pointSize: CGSize(width: 10, height: 10), scale: 1, target: "t")
        try store.recordBefore(name: name, capture: shot, target: "web:https://x.dev")

        // The property that matters is containment: exactly one directory, created
        // inside the root. `..-..-etc-passwd` is a fine name; `..` is not.
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents.count == 1)
        #expect(contents[0] != "..")
        #expect(contents[0] != ".")
        #expect(!contents[0].contains("/"))
        #expect(
            store.beforeURL(name).standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path))
    }
}

@Suite("Coordinate spaces")
struct CoordinateSpaceTests {
    /// A Retina window at (100, 50), 800×600 points.
    let window = Frame(x: 100, y: 50, width: 800, height: 600)

    /// One way of naming a point: the space, and the pair of numbers read in it.
    struct Naming {
        let space: CoordinateSpace
        let x: Double
        let y: Double
    }

    /// A `click:` step and what it is expected to parse to.
    struct ClickCase {
        let step: String
        let space: CoordinateSpace
        let viaCursor: Bool
    }

    @Test("all four spaces name the same physical point")
    func agreement() {
        // The centre of the window, expressed four ways. If these ever disagree, a
        // click derived from a screenshot lands somewhere else entirely.
        let expected = (x: 500.0, y: 350.0)
        let namings: [Naming] = [
            Naming(space: .screenPoints, x: 500, y: 350),
            Naming(space: .windowPoints, x: 400, y: 300),
            Naming(space: .windowPixels, x: 800, y: 600),  // @2x
            Naming(space: .normalized, x: 0.5, y: 0.5)
        ]
        for naming in namings {
            let point = naming.space.toScreenPoint(
                x: naming.x, y: naming.y, windowFrame: window, backingScale: 2)
            #expect(abs(point.x - expected.x) < 0.001, Comment(rawValue: "\(naming.space) x"))
            #expect(abs(point.y - expected.y) < 0.001, Comment(rawValue: "\(naming.space) y"))
        }
    }

    @Test("pixel space follows the display's actual scale")
    func nonRetina() {
        // A window dragged to a 1x monitor: the same pixel coordinate is now half
        // as far from the origin. Assuming 2x would double every click offset.
        let retina = CoordinateSpace.windowPixels.toScreenPoint(
            x: 800, y: 600, windowFrame: window, backingScale: 2)
        let plain = CoordinateSpace.windowPixels.toScreenPoint(
            x: 800, y: 600, windowFrame: window, backingScale: 1)
        #expect(retina.x == 500)
        #expect(plain.x == 900)
    }

    @Test("normalized coordinates survive any rescaling")
    func normalizedIsScaleFree() {
        // The reason this space exists: an image delivered over MCP is downscaled,
        // so its pixels are neither points nor capture pixels — but a fraction of
        // the window is still a fraction of the window.
        for scale in [1.0, 2.0, 3.0] {
            let point = CoordinateSpace.normalized.toScreenPoint(
                x: 0.25, y: 0.75, windowFrame: window, backingScale: scale)
            #expect(point.x == 300)
            #expect(point.y == 500)
        }
    }

    @Test("step syntax names the space")
    func parsing() throws {
        let cases: [ClickCase] = [
            ClickCase(step: "click:120,340", space: .windowPoints, viaCursor: false),
            ClickCase(step: "click:px:240,680", space: .windowPixels, viaCursor: false),
            ClickCase(step: "click:n:0.5,0.33", space: .normalized, viaCursor: false),
            ClickCase(step: "click:screen:1500,900", space: .screenPoints, viaCursor: false),
            ClickCase(step: "cursorclick:n:0.5,0.5", space: .normalized, viaCursor: true)
        ]
        for expected in cases {
            let raw = expected.step
            guard case .click(_, _, let space, let viaCursor) = try UIAction.parse(step: raw) else {
                Issue.record(Comment(rawValue: "\(raw) did not parse as a click")); continue
            }
            #expect(space == expected.space, Comment(rawValue: raw))
            #expect(viaCursor == expected.viaCursor, Comment(rawValue: raw))
        }
    }

    @Test("normalized coordinates outside 0…1 are rejected")
    func rejectsOutOfRange() {
        // Almost always a pixel value pasted into the wrong space; silently
        // clamping would click the window's edge and look like a miss.
        #expect(throws: (any Error).self) { try UIAction.parse(step: "click:n:640,480") }
    }
}
