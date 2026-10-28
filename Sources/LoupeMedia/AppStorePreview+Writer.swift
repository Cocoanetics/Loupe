import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import LoupeCore
import VideoToolbox

// The moving parts behind `AppStorePreview.render`: reading frames out of a
// file, and the writer with its two inputs.

extension AppStorePreview {
    /// Pulls decoded frames out of a file, one at a time. Frames that cannot be
    /// turned into a picture are skipped, so the previous one is held.
    final class FrameReader: @unchecked Sendable {
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        private let crop: CGRect?

        init(asset: AVAsset, track: AVAssetTrack, crop: CGRect?) throws {
            reader = try AVAssetReader(asset: asset)
            output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            self.crop = crop
            guard reader.canAdd(output) else { throw MediaError.unreadable("cannot read the video track") }
            reader.add(output)
            guard reader.startReading() else {
                throw MediaError.unreadable(reader.error?.localizedDescription ?? "cannot read the video")
            }
        }

        func next() throws -> TimedFrame? {
            while let sample = output.copyNextSampleBuffer() {
                guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
                var image: CGImage?
                VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
                guard let full = image, let picture = crop.map({ full.cropping(to: $0) }) ?? full else { continue }
                return TimedFrame(
                    image: picture, time: max(CMSampleBufferGetPresentationTimeStamp(sample).seconds, 0))
            }
            if reader.status == .failed {
                throw MediaError.unreadable(reader.error?.localizedDescription ?? "reading failed")
            }
            return nil
        }

        func cancel() { reader.cancelReading() }
    }

    /// What the video feeder carries between the writer's callbacks. Touched
    /// from the video queue only.
    final class VideoFeed: @unchecked Sendable {
        var index = 0
        var current: CVPixelBuffer
        var upcoming: TimedFrame?

        init(current: CVPixelBuffer, upcoming: TimedFrame?) {
            self.current = current
            self.upcoming = upcoming
        }
    }

    /// Resumes the caller once both inputs are finished, or as soon as one fails.
    final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining = 2
        private var continuation: CheckedContinuation<Void, any Error>?

        func attach(_ continuation: CheckedContinuation<Void, any Error>) {
            lock.withLock { self.continuation = continuation }
        }

        func finished() {
            lock.withLock {
                remaining -= 1
                guard remaining == 0, let continuation else { return }
                self.continuation = nil
                continuation.resume()
            }
        }

        func failed(_ error: any Error) {
            lock.withLock {
                guard let continuation else { return }
                self.continuation = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// The writer, its two inputs, and the pictures going into it.
    ///
    /// Both inputs are fed from `requestMediaDataWhenReady` callbacks rather than
    /// a loop of our own: with two inputs the writer interleaves them, and holds
    /// one not-ready until the other catches up. A loop that waits on the video
    /// input before it has fed the audio one deadlocks on exactly that.
    final class Writer: @unchecked Sendable {
        private let writer: AVAssetWriter
        private let video: AVAssetWriterInput
        private let adaptor: AVAssetWriterInputPixelBufferAdaptor
        private let audio: AVAssetWriterInput
        private let audioFormat: CMAudioFormatDescription
        private let preset: Preset
        private let videoQueue = DispatchQueue(label: "com.cocoanetics.loupe.appstore.video")
        private let audioQueue = DispatchQueue(label: "com.cocoanetics.loupe.appstore.audio")

        init(destination: URL, preset: Preset) throws {
            self.preset = preset
            try? FileManager.default.removeItem(at: destination)
            writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
            video = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: preset.width,
                    AVVideoHeightKey: preset.height,
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: bitRate,
                        AVVideoProfileLevelKey: AVVideoProfileLevelH264High40,
                        AVVideoExpectedSourceFrameRateKey: frameRate,
                        AVVideoMaxKeyFrameIntervalKey: frameRate,
                        AVVideoAllowFrameReorderingKey: false
                    ]
                ])
            video.expectsMediaDataInRealTime = false
            adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: video,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: preset.width,
                    kCVPixelBufferHeightKey as String: preset.height
                ])
            audio = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: audioSampleRate,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: audioBitRate
                ])
            audio.expectsMediaDataInRealTime = false
            audioFormat = try Self.silenceFormat()
            guard writer.canAdd(video), writer.canAdd(audio) else {
                throw MediaError.encodeFailed("cannot write H.264 with an AAC track")
            }
            writer.add(video)
            writer.add(audio)
            guard writer.startWriting() else {
                throw MediaError.encodeFailed(writer.error?.localizedDescription ?? "cannot start writing")
            }
            writer.startSession(atSourceTime: .zero)
        }

        /// Feeds both inputs until the preview is `seconds` long, then finalizes.
        func write(
            frames: Int, seconds: TimeInterval, choice: Choice, first: TimedFrame,
            next: @escaping @Sendable () throws -> TimedFrame?
        ) async throws {
            let feed = VideoFeed(current: try rendered(first.image, choice: choice), upcoming: try next())
            let completion = Completion()
            let samples = Int64((seconds * audioSampleRate).rounded())
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    completion.attach(continuation)
                    feedVideo(feed, frames: frames, choice: choice, next: next, completion: completion)
                    feedAudio(samples: samples, completion: completion)
                }
            } catch {
                writer.cancelWriting()
                throw error
            }
            writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw MediaError.encodeFailed(writer.error?.localizedDescription ?? "the preview was not written")
            }
        }

        private func feedVideo(
            _ feed: VideoFeed, frames: Int, choice: Choice, next: @escaping @Sendable () throws -> TimedFrame?,
            completion: Completion
        ) {
            video.requestMediaDataWhenReady(on: videoQueue) { [self] in
                do {
                    while video.isReadyForMoreMediaData {
                        guard feed.index < frames else {
                            video.markAsFinished()
                            completion.finished()
                            return
                        }
                        let time = Double(feed.index) / Double(frameRate)
                        while let frame = feed.upcoming, frame.time <= time + 1e-6 {
                            feed.current = try rendered(frame.image, choice: choice)
                            feed.upcoming = try next()
                        }
                        let stamp = CMTime(value: CMTimeValue(feed.index * 600 / frameRate), timescale: 600)
                        guard adaptor.append(feed.current, withPresentationTime: stamp) else {
                            throw MediaError.encodeFailed(
                                writer.error?.localizedDescription ?? "could not write a frame")
                        }
                        feed.index += 1
                    }
                } catch {
                    video.markAsFinished()
                    completion.failed(error)
                }
            }
        }

        private func feedAudio(samples: Int64, completion: Completion) {
            let position = Locked<Int64>(0)
            audio.requestMediaDataWhenReady(on: audioQueue) { [self] in
                do {
                    while audio.isReadyForMoreMediaData {
                        let start = position.value
                        guard start < samples else {
                            audio.markAsFinished()
                            completion.finished()
                            return
                        }
                        // A tenth of a second at a time.
                        let end = min(start + 4410, samples)
                        try appendSilence(from: start, until: end)
                        position.value = end
                    }
                } catch {
                    audio.markAsFinished()
                    completion.failed(error)
                }
            }
        }

        /// `image` scaled into a frame of the preset's size, black where it does
        /// not reach.
        private func rendered(_ image: CGImage, choice: Choice) throws -> CVPixelBuffer {
            var made: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            }
            if made == nil {
                CVPixelBufferCreate(nil, preset.width, preset.height, kCVPixelFormatType_32BGRA, nil, &made)
            }
            guard let buffer = made else { throw MediaError.encodeFailed("could not allocate a frame") }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard
                let context = CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer), width: preset.width, height: preset.height,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue)
            else { throw MediaError.encodeFailed("could not draw into a frame") }
            context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: preset.width, height: preset.height))
            context.interpolationQuality = .high
            context.draw(
                image,
                in: placement(sourceWidth: image.width, sourceHeight: image.height, in: choice))
            return buffer
        }

        /// Stereo 16-bit silence covering sample positions `start..<end`.
        private func appendSilence(from start: Int64, until end: Int64) throws {
            let count = Int(end - start)
            guard count > 0 else { return }
            let bytes = count * 4
            var block: CMBlockBuffer?
            guard
                CMBlockBufferCreateWithMemoryBlock(
                    allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                    customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                    blockBufferOut: &block) == noErr, let block,
                CMBlockBufferFillDataBytes(
                    with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr
            else { throw MediaError.encodeFailed("could not allocate silence") }
            var sample: CMSampleBuffer?
            guard
                CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                    allocator: nil, dataBuffer: block, formatDescription: audioFormat, sampleCount: count,
                    presentationTimeStamp: CMTime(value: start, timescale: CMTimeScale(audioSampleRate)),
                    packetDescriptions: nil, sampleBufferOut: &sample) == noErr, let sample
            else { throw MediaError.encodeFailed("could not describe silence") }
            guard audio.append(sample) else {
                throw MediaError.encodeFailed(writer.error?.localizedDescription ?? "could not write audio")
            }
        }

        private static func silenceFormat() throws -> CMAudioFormatDescription {
            var description = AudioStreamBasicDescription(
                mSampleRate: audioSampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
                mBitsPerChannel: 16, mReserved: 0)
            var format: CMAudioFormatDescription?
            guard
                CMAudioFormatDescriptionCreate(
                    allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                    magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format
            else { throw MediaError.encodeFailed("could not describe the audio format") }
            return format
        }
    }
}

/// A value behind a lock, for the one counter the audio feeder keeps between
/// callbacks.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
