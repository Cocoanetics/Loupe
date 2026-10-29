import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import LoupeCore
import ScreenCaptureKit

/// The output size of a recording and how later frames fit into it.
///
/// A movie has one size. The first frame sets it; a window resized during the
/// recording is scaled to fit inside that size, centred, never stretched.
struct RecordingSize: Equatable, Sendable {
    let width: Int
    let height: Int

    /// H.264 wants even dimensions. Nil when the frame has no area.
    init?(firstFrameWidth: Int, height: Int) {
        let evenWidth = firstFrameWidth - firstFrameWidth % 2
        let evenHeight = height - height % 2
        guard evenWidth >= 2, evenHeight >= 2 else { return nil }
        self.width = evenWidth
        self.height = evenHeight
    }

    /// Where a frame of the given size is drawn, bottom-left origin as Core
    /// Image expects. A frame of exactly the locked size fills it.
    func placement(ofFrameWidth frameWidth: Int, height frameHeight: Int) -> CGRect {
        guard frameWidth > 0, frameHeight > 0 else { return .zero }
        let fit = min(Double(width) / Double(frameWidth), Double(height) / Double(frameHeight))
        let drawn = CGSize(width: Double(frameWidth) * fit, height: Double(frameHeight) * fit)
        return CGRect(
            x: (Double(width) - drawn.width) / 2, y: (Double(height) - drawn.height) / 2,
            width: drawn.width, height: drawn.height)
    }

    func matches(frameWidth: Int, height frameHeight: Int) -> Bool {
        frameWidth == width && frameHeight == height
    }
}

/// When `stop()` repeats the last frame so a still window keeps its length.
///
/// The container's duration comes from its last sample, not from the session
/// end, so a window that sent one frame would play as one frame. Repeating that
/// picture one frame before the end fixes the length for every player.
enum RecordingTail {
    static let frameInterval = CMTime(value: 1, timescale: 30)

    /// The time to append the last frame again, or nil when the last sample
    /// already reaches the frame before `held`.
    static func repeatTime(last: CMTime, held: CMTime, frameInterval: CMTime = frameInterval) -> CMTime? {
        let tail = CMTimeSubtract(held, frameInterval)
        return CMTimeCompare(tail, last) > 0 ? tail : nil
    }
}

/// Turning a region of the window into what ScreenCaptureKit films.
///
/// Regions are **window-relative points, top-left origin** — unlike a capture
/// region, which is in global screen points. An element's frame arrives in global
/// screen points and is moved into the window first.
enum WindowRegion {
    struct Source {
        var rect: CGRect
        var pixelWidth: Int
        var pixelHeight: Int
    }

    /// A global-screen-points frame, relative to the window's top-left corner.
    static func relative(global frame: Frame, toWindowAt window: CGRect) -> Frame {
        Frame(
            x: frame.x - window.origin.x, y: frame.y - window.origin.y,
            width: frame.width, height: frame.height)
    }

    /// The `SCStreamConfiguration.sourceRect` (points, inside the window content)
    /// and the output size in pixels. The pixel size is the region times the
    /// backing scale, snapped outward to even numbers for H.264. Throws when the
    /// region is empty or reaches outside the window.
    static func source(_ region: Frame, contentSize: CGSize, scale: Double) throws -> Source {
        let pixels = try RecordCrop.pixelRect(
            region, scale: scale, pixelWidth: Int((contentSize.width * scale).rounded()),
            pixelHeight: Int((contentSize.height * scale).rounded()))
        let rect = CGRect(
            x: pixels.minX / scale, y: pixels.minY / scale,
            width: pixels.width / scale, height: pixels.height / scale)
        return Source(rect: rect, pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height))
    }
}

extension MacDriver: RecordingDriver {
    nonisolated public var cropsRegionAtSource: Bool { true }

    public func startRecording(to url: URL, options: RecordOptions) async throws
        -> any RecordingHandle {
        try requireResolved()
        try ensureResolved()
        guard let window = windowElement, let application = runningApplication else {
            throw LoupeError.targetNotFound(appLocator)
        }
        // ScreenCaptureKit pauses a window stream while the window is minimized, so
        // no frame would ever arrive. Say so now rather than after the recording.
        if AXAPI.bool(window, kAXMinimizedAttribute) == true {
            throw LoupeError.failed(
                "\(resolvedDescription) is minimized, and macOS delivers no video of a minimized window. "
                    + "Restore it (an occluded or other-Space window is fine) and record again.")
        }
        var region: Frame?
        switch options.region {
            case .frame(let frame):
                region = frame
            case .element(let needle, let padding):
                let node = try await resolve(needle)
                guard let frame = node.frame, !frame.isEmpty, let windowFrame = AXAPI.frame(window) else {
                    throw LoupeError.failed("'\(needle)' has no frame to record")
                }
                let inWindow = WindowRegion.relative(
                    global: RecordCrop.padded(frame, by: padding),
                    toWindowAt: CGRect(
                        x: windowFrame.x, y: windowFrame.y, width: windowFrame.width,
                        height: windowFrame.height))
                // Padding may reach past the window edge; the element itself is what was asked for.
                guard let kept = RecordCrop.clamped(
                    inWindow, toWidth: windowFrame.width, height: windowFrame.height)
                else {
                    throw LoupeError.failed("'\(needle)' lies outside the window")
                }
                region = kept
            case nil:
                break
        }
        try? FileManager.default.removeItem(at: url)
        return try await WindowRecording.start(
            captureTarget(for: window, of: application), to: url, region: region)
    }
}

/// One window filmed through ScreenCaptureKit into an `AVAssetWriter`.
///
/// ScreenCaptureKit renders the window itself, so minimized, hidden, occluded
/// and other-Space windows are filmed as `capture` photographs them. It only
/// delivers a frame when something changed, so the movie has variable timing and
/// `stop()` extends the last frame to the moment of stopping.
final class WindowRecording: NSObject, RecordingHandle, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable {
    private struct State {
        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        var size: RecordingSize?
        var firstTime: CMTime?
        /// When the first frame was appended, on the wall clock `stop()` reads.
        var firstAt: Date?
        var lastTime: CMTime?
        /// The buffer last handed to the adaptor, after any fitting.
        var lastPixels: CVPixelBuffer?
        var frames = 0
        var resized = false
        var failure: String?
        var stopped = false
        var closed = false
    }

    private let url: URL
    private(set) var stream: SCStream!
    private let startedAt = Date()
    private let state = NSLock()
    private var current = State()
    private let queue = DispatchQueue(label: "com.cocoanetics.loupe.window.record", qos: .userInitiated)
    private let context = CIContext()

    private init(url: URL) {
        self.url = url
        super.init()
    }

    private func withState<T>(_ body: (inout State) -> T) -> T {
        state.lock()
        defer { state.unlock() }
        return body(&current)
    }

    static func start(_ target: CaptureTarget, to url: URL, region: Frame?) async throws -> WindowRecording {
        let window = try await WindowCapture.locate(target)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = Double(filter.pointPixelScale)

        let configuration = SCStreamConfiguration()
        configuration.width = Int((filter.contentRect.width * scale).rounded())
        configuration.height = Int((filter.contentRect.height * scale).rounded())
        if let region {
            // Fixed relative to the window's top-left; if the window is resized later,
            // ScreenCaptureKit clips it and the size lock fits what arrives.
            let source = try WindowRegion.source(region, contentSize: filter.contentRect.size, scale: scale)
            configuration.sourceRect = source.rect
            configuration.width = source.pixelWidth
            configuration.height = source.pixelHeight
        }
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = true
        configuration.scalesToFit = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6

        let recording = WindowRecording(url: url)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: recording)
        recording.stream = stream
        do {
            try stream.addStreamOutput(recording, type: .screen, sampleHandlerQueue: recording.queue)
            try await stream.startCapture()
        } catch {
            if isScreenLocked() {
                throw LoupeError.failed(
                    "cannot record while the screen is locked — macOS stops all screen capture "
                        + "until someone unlocks it. Accessibility still works; only video is unavailable.")
            }
            throw LoupeError.failed(
                "ScreenCaptureKit could not start recording window #\(window.windowID): "
                    + error.localizedDescription)
        }
        return recording
    }

    // MARK: frames

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        // Idle and blank frames carry no pixels worth writing.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let raw = attachments.first?[.status] as? Int,
            SCFrameStatus(rawValue: raw) == .complete
        else { return }
        let time = buffer.presentationTimeStamp
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)

        withState { state in
            guard !state.closed, state.failure == nil else { return }
            if state.writer == nil {
                guard let size = RecordingSize(firstFrameWidth: width, height: height) else { return }
                do {
                    try openWriter(&state, size: size, time: time)
                } catch {
                    state.failure = error.localizedDescription
                    return
                }
            }
            guard let size = state.size, let input = state.input, let adaptor = state.adaptor,
                input.isReadyForMoreMediaData
            else { return }
            var output = pixels
            if !size.matches(frameWidth: width, height: height) {
                state.resized = true
                guard let fitted = fit(pixels, into: size, adaptor: adaptor) else { return }
                output = fitted
            }
            if adaptor.append(output, withPresentationTime: time) {
                state.frames += 1
                state.lastTime = time
                state.lastPixels = output
                state.firstAt = state.firstAt ?? Date()
            } else {
                state.failure = state.writer?.error?.localizedDescription ?? "the video writer failed"
            }
        }
    }

    private func openWriter(_ state: inout State, size: RecordingSize, time: CMTime) throws {
        let type: AVFileType = url.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height
            ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height
            ])
        guard writer.canAdd(input) else {
            throw LoupeError.failed("the video writer rejected the \(size.width)x\(size.height) input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw LoupeError.failed(
                "could not start writing \(url.lastPathComponent): "
                    + (writer.error?.localizedDescription ?? "unknown error"))
        }
        writer.startSession(atSourceTime: time)
        state.writer = writer
        state.input = input
        state.adaptor = adaptor
        state.size = size
        state.firstTime = time
    }

    /// Draws a frame of another size into the locked one, on black.
    private func fit(
        _ pixels: CVPixelBuffer, into size: RecordingSize, adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var target: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target) == kCVReturnSuccess, let target else {
            return nil
        }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let place = size.placement(ofFrameWidth: width, height: height)
        let scaled = CIImage(cvPixelBuffer: pixels)
            .transformed(by: CGAffineTransform(scaleX: place.width / Double(width), y: place.height / Double(height)))
            .transformed(by: CGAffineTransform(translationX: place.minX, y: place.minY))
        let canvas = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let black = CIImage(color: .black).cropped(to: canvas)
        context.render(
            scaled.composited(over: black), to: target, bounds: canvas,
            colorSpace: CGColorSpaceCreateDeviceRGB())
        return target
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        withState { $0.failure = $0.failure ?? error.localizedDescription }
    }

    // MARK: stop

    func stop() async throws -> RecordingResult {
        let first = withState { state -> Bool in
            defer { state.stopped = true }
            return !state.stopped
        }
        guard first else { throw LoupeError.failed("this recording was already stopped") }
        let stoppedAt = Date()
        // The stream may already be gone (the window closed); the file is still finished below.
        try? await stream.stopCapture()
        // Let any buffer already in flight land before the writer is closed.
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }

        withState { $0.closed = true }
        let (writer, input, adaptor, frames, resized, failure, opened, firstAt, last, lastPixels) = withState {
            ($0.writer, $0.input, $0.adaptor, $0.frames, $0.resized, $0.failure, $0.firstTime, $0.firstAt,
             $0.lastTime, $0.lastPixels)
        }
        guard let writer, let input, frames > 0, let last else {
            throw LoupeError.failed(
                "no frames were recorded from the window"
                    + (failure.map { ": \($0)" } ?? " — it may have shown nothing, or the screen is locked"))
        }
        // Measured from the first frame, not from `startedAt`: the stream takes a
        // moment to start, and the caller's wait only begins once it has. A first
        // frame that only landed while the stream was stopping counts as zero.
        let duration = max(0, stoppedAt.timeIntervalSince(firstAt ?? startedAt))
        // Hold the last frame up to the moment of stopping; idle windows send nothing.
        let held = CMTimeAdd(opened ?? last, CMTime(seconds: duration, preferredTimescale: 600))
        if let adaptor, let lastPixels, let tail = RecordingTail.repeatTime(last: last, held: held) {
            // A real-time input may be briefly busy with the last frame; wait up to a second.
            var waits = 0
            while !input.isReadyForMoreMediaData, writer.status == .writing, waits < 200 {
                try? await Task.sleep(for: .milliseconds(5))
                waits += 1
            }
            if input.isReadyForMoreMediaData {
                _ = adaptor.append(lastPixels, withPresentationTime: tail)
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: max(held, last))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw LoupeError.failed(
                "could not finish \(url.lastPathComponent): "
                    + (writer.error?.localizedDescription ?? failure ?? "unknown error"))
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw LoupeError.failed("the recording of the window is empty") }
        var result = RecordingResult(url: url, duration: duration, bytes: size)
        if resized {
            result.notes.append(
                "the window was resized while recording; later frames were fitted to the first frame's size")
        }
        if let failure {
            result.notes.append("recording ended early: \(failure)")
        }
        return result
    }
}
