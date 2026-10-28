import CoreGraphics
import Foundation
import ImageIO
import LoupeCore
@testable import LoupeKit
@testable import LoupeMac
@testable import LoupeMedia
import Testing

/// A recorder that films nothing and says what was asked of it.
private final class FakeRecorder: RecordingDriver, @unchecked Sendable {
    let targetDescription = "fake"
    let actionDuration: Double
    private let lock = NSLock()
    private var stops = 0

    init(actionDuration: Double) { self.actionDuration = actionDuration }

    var stopCount: Int { lock.withLock { stops } }

    func capture(_ options: CaptureOptions) async throws -> Capture {
        throw LoupeError.unsupported("fake")
    }

    func describe(_ options: DescribeOptions) async throws -> [UINode] { [] }

    func perform(_ action: UIAction) async throws -> ActionResult {
        try await Task.sleep(for: .seconds(actionDuration))
        return ActionResult(message: "done")
    }

    func startRecording(to url: URL, options: RecordOptions) async throws -> any RecordingHandle {
        Handle(owner: self, url: url)
    }

    private struct Handle: RecordingHandle {
        let owner: FakeRecorder
        let url: URL

        func stop() async throws -> RecordingResult {
            owner.lock.withLock { owner.stops += 1 }
            return RecordingResult(url: url, duration: 0, bytes: 1)
        }
    }
}

@Suite struct RecordTests {
    private func solid(_ gray: UInt8, size: Int = 64) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let value = CGFloat(gray) / 255
        context.setFillColor(red: value, green: value, blue: value, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()!
    }

    private func frames(_ grays: [UInt8], step: Double = 0.1) -> [TimedFrame] {
        grays.enumerated().map { TimedFrame(image: solid($1), time: Double($0) * step) }
    }

    @Test func identicalFramesCollapseIntoOneLongHold() throws {
        let held = try FrameCollapser.collapse(
            frames([10, 10, 10, 10, 200]), endTime: 0.5, threshold: 0.002)
        #expect(held.count == 2)
        #expect(abs(held[0].delay - 0.4) < 0.001)
        #expect(abs(held[1].delay - 0.1) < 0.001)
    }

    @Test func slowDriftIsComparedAgainstTheLastKeptFrame() throws {
        // Each step is 1/255 apart (0.4%) but the threshold is 1%: comparing
        // neighbours would keep one frame, comparing to the kept frame keeps more.
        let held = try FrameCollapser.collapse(
            frames([100, 101, 102, 103, 104, 105]), endTime: 0.6, threshold: 0.01)
        #expect(held.count > 1)
        #expect(abs(held.map(\.delay).reduce(0, +) - 0.6) < 0.001)
    }

    @Test func delaysAreClamped() throws {
        let held = try FrameCollapser.collapse(
            [TimedFrame(image: solid(0), time: 0), TimedFrame(image: solid(255), time: 0.001)],
            endTime: 0.002, threshold: 0.002)
        #expect(held.allSatisfy { $0.delay >= FrameCollapser.minDelay })
        let long = try FrameCollapser.collapse(frames([5]), endTime: 5000, threshold: 0.002)
        #expect(long[0].delay == FrameCollapser.maxDelay)
    }

    @Test func gifRoundTripsFrameCountAndDelays() throws {
        let held = [HeldFrame(image: solid(0), delay: 2.5), HeldFrame(image: solid(255), delay: 0.2)]
        let data = try GIFEncoder.encode(held)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 2)
        func delay(_ index: Int) -> Double? {
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return gif?[kCGImagePropertyGIFDelayTime] as? Double
        }
        #expect(abs((delay(0) ?? 0) - 2.5) < 0.011)
        #expect(abs((delay(1) ?? 0) - 0.2) < 0.011)
        let file = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let loops = (file?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount]
        #expect(loops as? Int == 0)
    }

    @Test func noLoopPlaysOnce() throws {
        let data = try GIFEncoder.encode([HeldFrame(image: solid(0), delay: 1)], loop: false)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let file = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let gif = file?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        // Readers report an absent loop block as one play; "forever" is 0.
        #expect(gif?[kCGImagePropertyGIFLoopCount] as? Int != 0)
    }

    @Test func durationsParse() throws {
        #expect(try DurationSpec.parse("10s") == 10)
        #expect(try DurationSpec.parse("500ms") == 0.5)
        #expect(try DurationSpec.parse("2m") == 120)
        #expect(try DurationSpec.parse("3") == 3)
        #expect(throws: LoupeError.self) { try DurationSpec.parse("soon") }
        #expect(throws: LoupeError.self) { try DurationSpec.parse("-1s") }
    }

    @Test func maxDurationCannotExceedTheHardLimit() {
        #expect(RecordOptions(maxDuration: 9999).maxDuration == RecordOptions.hardLimit)
    }

    // MARK: crop math

    @Test func regionParsingIsStrict() throws {
        let frame = try RecordCrop.parse("10, 20,300,40.5")
        #expect(frame == Frame(x: 10, y: 20, width: 300, height: 40.5))
        #expect(throws: LoupeError.self) { try RecordCrop.parse("1,2,3") }
        #expect(throws: LoupeError.self) { try RecordCrop.parse("1,2,3,x") }
    }

    @Test func pointsBecomePixelsFromTheTopLeft() throws {
        // 390×844 pt at 3x is 1170×2532 px.
        let rect = try RecordCrop.pixelRect(
            Frame(x: 10, y: 100, width: 200, height: 50), scale: 3, pixelWidth: 1170, pixelHeight: 2532)
        #expect(rect == CGRect(x: 30, y: 300, width: 600, height: 150))
    }

    @Test func pixelRectsSnapOutwardToEvenSizes() throws {
        let rect = try RecordCrop.pixelRect(
            Frame(x: 0.5, y: 0.5, width: 10, height: 10), scale: 3, pixelWidth: 1170, pixelHeight: 2532)
        #expect(Int(rect.minX) % 2 == 0 && Int(rect.minY) % 2 == 0)
        #expect(Int(rect.width) % 2 == 0 && Int(rect.height) % 2 == 0)
        // Outward: the 1.5…31.5 px span is still covered.
        #expect(rect.minX <= 1.5 && rect.maxX >= 31.5)
    }

    @Test func regionsOutsideTheScreenAreRejected() {
        for region in [
            Frame(x: 300, y: 0, width: 200, height: 50), Frame(x: -20, y: 0, width: 50, height: 50),
            Frame(x: 0, y: 800, width: 50, height: 100), Frame(x: 0, y: 0, width: 0, height: 10)
        ] {
            #expect(throws: LoupeError.self) {
                try RecordCrop.pixelRect(region, scale: 3, pixelWidth: 1170, pixelHeight: 2532)
            }
        }
    }

    @Test func fullScreenIsAValidRegion() throws {
        let rect = try RecordCrop.pixelRect(
            Frame(x: 0, y: 0, width: 390, height: 844), scale: 3, pixelWidth: 1170, pixelHeight: 2532)
        #expect(rect == CGRect(x: 0, y: 0, width: 1170, height: 2532))
    }

    @Test func paddingGrowsAndClampingKeepsTheScreen() throws {
        let grown = RecordCrop.padded(Frame(x: 4, y: 4, width: 100, height: 40), by: 8)
        #expect(grown == Frame(x: -4, y: -4, width: 116, height: 56))
        let kept = try #require(RecordCrop.clamped(grown, toWidth: 390, height: 844))
        #expect(kept == Frame(x: 0, y: 0, width: 112, height: 52))
        #expect(RecordCrop.clamped(Frame(x: 500, y: 0, width: 10, height: 10), toWidth: 390, height: 844) == nil)
    }

    // MARK: bounds

    @Test func theCapCoversActionsThatRunLongerThanIt() async throws {
        let recorder = FakeRecorder(actionDuration: 3)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID()).mp4")
        let started = Date()
        await #expect(throws: LoupeError.self) {
            _ = try await Loupe.recordSession(
                on: recorder,
                Loupe.Session(
                    url: url, record: RecordOptions(maxDuration: 0.3), region: nil,
                    actions: [.navigate("x")], stop: .after(0.1)))
        }
        #expect(Date().timeIntervalSince(started) < 2)
        // Whatever went wrong, the recording was still stopped.
        #expect(recorder.stopCount == 1)
    }

    @Test func theClosingWaitGetsOnlyWhatTheActionsLeft() async throws {
        let recorder = FakeRecorder(actionDuration: 0.25)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID()).mp4")
        let started = Date()
        _ = try await Loupe.recordSession(
            on: recorder,
            Loupe.Session(
                url: url, record: RecordOptions(maxDuration: 0.4), region: nil,
                actions: [.navigate("x")], stop: .after(5)))
        // 0.25s of action plus at most the remaining 0.15s, not a full 5s tail.
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(recorder.stopCount == 1)
    }

    // MARK: streaming conversion

    @Test func conversionHoldsOneFrameNoMatterHowLongTheClip() async throws {
        let still = solid(40)
        let moved = solid(220)
        var pulled = 0
        let result = try await VideoConverter.encode(
            sampleCount: 500, duration: 50, options: GIFOptions(threshold: 0.002)
        ) { index in
            pulled += 1
            return TimedFrame(image: index >= 250 ? moved : still, time: Double(index) * 0.1)
        }
        #expect(pulled == 500)
        #expect(result.sampledFrames == 500)
        #expect(result.keptFrames == 2)
        // The pending frame is the only one kept: 1, not 500.
        #expect(result.peakRetainedFrames == 1)
        let source = try #require(CGImageSourceCreateWithData(result.data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 2)
    }

    @Test func conversionSkipsSamplesThatCouldNotBeRead() async throws {
        let result = try await VideoConverter.encode(
            sampleCount: 4, duration: 4, options: GIFOptions()
        ) { index in
            index == 1 ? nil : TimedFrame(image: self.solid(UInt8(index * 80)), time: Double(index))
        }
        #expect(result.sampledFrames == 3)
        await #expect(throws: MediaError.self) {
            _ = try await VideoConverter.encode(sampleCount: 2, duration: 2, options: GIFOptions()) { _ in nil }
        }
    }

    @Test func cancellingTheCallerStopsActionsAtOnceAndStillFinalizes() async throws {
        let recorder = FakeRecorder(actionDuration: 30)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID()).mp4")
        let started = Date()
        let task = Task {
            try await Loupe.recordSession(
                on: recorder,
                Loupe.Session(
                    url: url, record: RecordOptions(maxDuration: 60), region: nil,
                    actions: [.navigate("x")], stop: .after(5)))
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let result = try await task.value
        // Ctrl-C is a graceful stop: finalized and returned, not 30s or 60s later.
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(result.url == url)
        #expect(recorder.stopCount == 1)
    }
}

// MARK: - mac: recording

/// A Mac-surface driver that records, as `MacDriver` now does.
private final class FakeMac: RecordingDriver, @unchecked Sendable {
    let targetDescription = "mac:Fake"
    var started: URL?
    func capture(_ options: CaptureOptions) async throws -> Capture { throw LoupeError.unsupported("fake") }
    func describe(_ options: DescribeOptions) async throws -> [UINode] { [] }
    func perform(_ action: UIAction) async throws -> ActionResult { ActionResult(message: "ok") }
    func startRecording(to url: URL, options: RecordOptions) async throws -> any RecordingHandle {
        started = url
        return FakeMacHandle(url: url)
    }
}

private struct FakeMacHandle: RecordingHandle {
    let url: URL
    func stop() async throws -> RecordingResult { RecordingResult(url: url, duration: 0, bytes: 1) }
}

@Suite struct MacRecordingTests {
    private func window(
        _ id: UInt32, pid: Int32 = 7, title: String? = nil, frame: CGRect = CGRect(x: 0, y: 0, width: 400, height: 300),
        layer: Int = 0
    ) -> WindowInfo {
        WindowInfo(id: id, pid: pid, title: title, frame: frame, layer: layer)
    }

    private func target(
        number: UInt32? = nil, title: String? = nil, frame: Frame? = nil
    ) -> CaptureTarget {
        CaptureTarget(pid: 7, windowNumber: number, title: title, frame: frame, appName: "mac:Fake")
    }

    @Test func windowNumberWinsThenFrameThenTitleThenLargest() {
        let small = window(1, title: "A", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let big = window(2, title: "B", frame: CGRect(x: 50, y: 50, width: 800, height: 600))
        let other = window(3, pid: 99, title: "A", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let all = [small, big, other]
        #expect(WindowCapture.match(all, target: target(number: 3)) == 3)
        #expect(
            WindowCapture.match(all, target: target(number: 42, frame: Frame(x: 1, y: 1, width: 100, height: 100)))
                == 1)
        #expect(WindowCapture.match(all, target: target(title: "B")) == 2)
        #expect(WindowCapture.match(all, target: target()) == 2)
        #expect(WindowCapture.match([other], target: target()) == nil)
    }

    @Test func sizeLocksToEvenDimensionsOfTheFirstFrame() throws {
        let size = try #require(RecordingSize(firstFrameWidth: 801, height: 601))
        #expect(size.width == 800 && size.height == 600)
        #expect(RecordingSize(firstFrameWidth: 1, height: 600) == nil)
        #expect(size.matches(frameWidth: 800, height: 600))
        #expect(!size.matches(frameWidth: 801, height: 600))
    }

    @Test func laterFramesFitInsideTheLockedSizeWithoutStretching() throws {
        let size = try #require(RecordingSize(firstFrameWidth: 800, height: 600))
        #expect(size.placement(ofFrameWidth: 800, height: 600) == CGRect(x: 0, y: 0, width: 800, height: 600))
        // Twice as wide: scaled to half height, centred vertically.
        #expect(size.placement(ofFrameWidth: 1600, height: 600) == CGRect(x: 0, y: 150, width: 800, height: 300))
        // Smaller window grows to fill what the aspect ratio allows.
        #expect(size.placement(ofFrameWidth: 200, height: 300) == CGRect(x: 200, y: 0, width: 400, height: 600))
    }

    @Test func macDriverIsARecordingDriver() {
        #expect(MacDriver(appLocator: "Fake") as Any is any RecordingDriver)
    }

    @Test func recordsThroughTheDriverSessionPath() async throws {
        let recorder = FakeMac()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mac-\(UUID()).mp4")
        let result = try await Loupe.recordSession(
            on: recorder,
            Loupe.Session(url: url, record: .default, region: nil, actions: [], stop: .after(0.05)))
        #expect(recorder.started == url)
        #expect(result.url == url)
    }

    @Test func regionsAreRefusedForMacWindows() async throws {
        let target = try Target.parse("mac:Fake")
        await #expect(throws: LoupeError.self) {
            _ = try await Loupe.record(
                target, to: URL(fileURLWithPath: "/tmp/x.mp4"),
                region: .frame(Frame(x: 0, y: 0, width: 10, height: 10)), stop: .after(0.1))
        }
    }
}
