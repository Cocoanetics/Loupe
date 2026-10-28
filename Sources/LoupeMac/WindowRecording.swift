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

extension MacDriver: RecordingDriver {
    public func startRecording(to url: URL, options: RecordOptions) async throws
        -> any RecordingHandle {
        try requireResolved()
        try ensureResolved()
        guard let window = windowElement, let application = runningApplication else {
            throw LoupeError.targetNotFound(appLocator)
        }
        try? FileManager.default.removeItem(at: url)
        return try await WindowRecording.start(
            captureTarget(for: window, of: application), to: url)
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
        var lastTime: CMTime?
        var frames = 0
        var resized = false
        var failure: String?
        var stopped = false
    }

    private let url: URL
    private let stream: SCStream
    private let startedAt = Date()
    private let state = NSLock()
    private var current = State()
    private let queue = DispatchQueue(label: "com.cocoanetics.loupe.window.record", qos: .userInitiated)
    private let context = CIContext()

    private init(url: URL, stream: SCStream) {
        self.url = url
        self.stream = stream
        super.init()
    }

    private func withState<T>(_ body: (inout State) -> T) -> T {
        state.lock()
        defer { state.unlock() }
        return body(&current)
    }

    static func start(_ target: CaptureTarget, to url: URL) async throws -> WindowRecording {
        let window = try await WindowCapture.locate(target)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = Double(filter.pointPixelScale)

        let configuration = SCStreamConfiguration()
        configuration.width = Int((filter.contentRect.width * scale).rounded())
        configuration.height = Int((filter.contentRect.height * scale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.ignoreShadowsSingleWindow = true
        configuration.scalesToFit = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let recording = WindowRecording(url: url, stream: stream)
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
            guard !state.stopped, state.failure == nil else { return }
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
        let duration = Date().timeIntervalSince(startedAt)
        // The stream may already be gone (the window closed); the file is still finished below.
        try? await stream.stopCapture()
        // Let any buffer already in flight land before the writer is closed.
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }

        let (writer, input, frames, resized, failure, opened, last) = withState {
            ($0.writer, $0.input, $0.frames, $0.resized, $0.failure, $0.firstTime, $0.lastTime)
        }
        guard let writer, let input, frames > 0, let last else {
            throw LoupeError.failed(
                "no frames were recorded from the window"
                    + (failure.map { ": \($0)" } ?? " — it may have shown nothing, or the screen is locked"))
        }
        input.markAsFinished()
        // Hold the last frame up to the moment of stopping; idle windows send nothing.
        let held = CMTimeAdd(opened ?? last, CMTime(seconds: duration, preferredTimescale: 600))
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
