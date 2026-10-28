import Foundation
import LoupeCore

/// What a recording should become once filming is over.
public struct RecordingRequest: Sendable {
    /// Where the result goes. A `.gif` path asks for the GIF alone; anything
    /// else is the video, with the GIF (if wanted) written next to it.
    public var output: URL
    /// Also write an animated GIF, with these settings.
    public var gif: GIFOptions?
    /// Render the video as an App Store preview instead of the screen-tuned
    /// H.264: an accepted resolution, 30 fps, 15–30 s, a silent stereo track.
    public var appStore: Bool
    /// Which device class the preview is for. Nil picks by the picture's shape.
    public var family: AppStorePreview.Family?

    public init(
        output: URL, gif: GIFOptions? = nil, appStore: Bool = false, family: AppStorePreview.Family? = nil
    ) {
        self.output = output
        self.gif = gif
        self.appStore = appStore
        self.family = family
    }

    public var gifOnly: Bool { output.pathExtension.lowercased() == "gif" }

    /// The video to write, or nil when only a GIF was asked for.
    public var videoURL: URL? { gifOnly ? nil : output }

    public var gifURL: URL? {
        if gifOnly { return output }
        guard gif != nil else { return nil }
        return output.deletingPathExtension().appendingPathExtension("gif")
    }
}

/// What came out of the pipeline.
public struct RecordingProduct: Sendable {
    public var video: URL?
    public var gif: URL?
    /// Wall-clock seconds filmed.
    public var duration: TimeInterval
    /// Size of the video, or of the GIF when that is all there is.
    public var bytes: Int
    /// What happened along the way, for a human: frame counts, fallbacks, the
    /// App Store preset chosen. Printed on stderr by the CLI, returned by MCP.
    public var notes: [String]

    public init(video: URL?, gif: URL?, duration: TimeInterval, bytes: Int, notes: [String]) {
        self.video = video
        self.gif = gif
        self.duration = duration
        self.bytes = bytes
        self.notes = notes
    }
}

/// Raw recording in, deliverables out — the one path from "the recorder stopped"
/// to files worth attaching, shared by the CLI, the MCP tool and `record stop`.
///
/// Filming is not done here: it is handed in as a closure, so this stays free of
/// drivers and the same steps run whether the frames came from `simctl`,
/// ScreenCaptureKit, or a live session's process.
public enum RecordingPipeline {

    /// Films into a scratch file, then encodes it as `request` asks.
    /// - Parameter film: records into the URL it is given and returns the result.
    public static func produce(
        _ request: RecordingRequest, film: (URL) async throws -> RecordingResult
    ) async throws -> RecordingProduct {
        let raw = scratchURL("loupe-raw", "mov")
        defer { try? FileManager.default.removeItem(at: raw) }
        let recording = try await film(raw)
        return try await encode(recording, as: request)
    }

    /// Turns a finished raw recording into the deliverables. The raw file is
    /// consumed once a video exists; if none could be written it is kept, and
    /// the error says where, because it is the only copy of what was filmed.
    public static func encode(
        _ recording: RecordingResult, as request: RecordingRequest
    ) async throws -> RecordingProduct {
        let raw = recording.url
        do {
            let product = try await deliver(recording, as: request)
            try? FileManager.default.removeItem(at: raw)
            return product
        } catch {
            guard let video = request.videoURL, size(of: video) == 0 else {
                try? FileManager.default.removeItem(at: raw)
                throw error
            }
            try? FileManager.default.removeItem(at: video)
            throw LoupeError.failed(
                "\(error.localizedDescription) — the raw recording was kept at \(raw.path)")
        }
    }

    private static func deliver(
        _ recording: RecordingResult, as request: RecordingRequest
    ) async throws -> RecordingProduct {
        let raw = recording.url
        var notes = recording.notes
        let crop = recording.region.flatMap { frame in
            recording.scale.map { ScreenCrop(region: frame, scale: $0) }
        }

        let video = request.videoURL ?? scratchURL("loupe-record", "mp4")
        defer { if request.videoURL == nil { try? FileManager.default.removeItem(at: video) } }
        try FileManager.default.createDirectory(
            at: video.deletingLastPathComponent(), withIntermediateDirectories: true)
        if request.appStore {
            let done = try await AppStorePreview.render(
                from: raw, to: video, crop: crop, family: request.family)
            notes += done.notes
        } else {
            notes += try await transcode(raw, to: video, crop: crop)
        }
        let videoBytes = size(of: video)
        notes.append(
            String(
                format: "recorded %.1fs, %@", recording.duration,
                ByteCountFormatter.string(fromByteCount: Int64(videoBytes), countStyle: .file)))

        var gif: URL?
        var bytes = videoBytes
        if let gifURL = request.gifURL {
            let result = try await VideoConverter.gif(from: video, options: request.gif ?? GIFOptions())
            try result.data.write(to: gifURL, options: .atomic)
            notes.append(
                String(
                    format: "gif: %d of %d sampled frames kept over %.1fs, %@",
                    result.keptFrames, result.sampledFrames, result.duration,
                    ByteCountFormatter.string(fromByteCount: Int64(result.data.count), countStyle: .file)))
            gif = gifURL
            if request.gifOnly { bytes = result.data.count }
        }
        return RecordingProduct(
            video: request.videoURL, gif: gif, duration: recording.duration, bytes: bytes, notes: notes)
    }

    /// The screen-tuned H.264 pass, falling back to the recorder's own file: a
    /// recording is never lost to a tuning step. If even the copy fails there
    /// is no video, and that is an error, not a note.
    private static func transcode(_ raw: URL, to video: URL, crop: ScreenCrop?) async throws -> [String] {
        do {
            let done = try await ScreenContentTranscoder.transcode(from: raw, to: video, crop: crop)
            return ["h264: \(done.writtenFrames) of \(done.sourceFrames) frames written (variable frame rate)"]
        } catch {
            try? FileManager.default.removeItem(at: video)
            let reason = error.localizedDescription
            do {
                try FileManager.default.copyItem(at: raw, to: video)
            } catch let copyError {
                throw MediaError.encodeFailed(
                    "could not optimize the video (\(reason)) nor copy the original to "
                        + "\(video.path): \(copyError.localizedDescription)")
            }
            let uncropped = crop == nil ? "" : ", NOT cropped"
            return ["note: could not optimize the video (\(reason)); kept the original encode\(uncropped)"]
        }
    }

    public static func scratchURL(_ prefix: String, _ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString).\(ext)")
    }

    private static func size(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}
