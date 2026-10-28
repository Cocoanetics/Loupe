import Foundation

/// Knobs for a screen recording.
public struct RecordOptions: Sendable {
    /// The longest a recording may run, whatever else was asked for. A recording
    /// that is never stopped fills a disk, so every way of ending one is bounded.
    public var maxDuration: TimeInterval

    public init(maxDuration: TimeInterval = RecordOptions.hardLimit) {
        self.maxDuration = min(max(maxDuration, 0.1), Self.hardLimit)
    }

    /// Ceiling no caller can raise.
    public static let hardLimit: TimeInterval = 120

    public static let `default` = RecordOptions()
}

/// A finished recording.
public struct RecordingResult: Sendable {
    public var url: URL
    /// Wall-clock seconds between the recording starting and being stopped.
    public var duration: TimeInterval
    public var bytes: Int
    public var notes: [String]

    public init(url: URL, duration: TimeInterval, bytes: Int, notes: [String] = []) {
        self.url = url
        self.duration = duration
        self.bytes = bytes
        self.notes = notes
    }
}

/// A recording in progress. `stop()` finalizes the file; skipping it leaves a
/// file that does not play, so every path out of a recording must reach it.
public protocol RecordingHandle: Sendable {
    func stop() async throws -> RecordingResult
}

/// An optional capability, kept apart from ``UIDriver`` so that protocol stays at
/// its five verbs: only drivers that can film their surface conform.
public protocol RecordingDriver: UIDriver {
    func startRecording(to url: URL, options: RecordOptions) async throws -> any RecordingHandle
}

/// The `10s`, `500ms`, `2m` spelling of a duration. A bare number is seconds.
public enum DurationSpec {
    public static func parse(_ text: String) throws -> TimeInterval {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let units: [(suffix: String, factor: Double)] = [("ms", 0.001), ("s", 1), ("m", 60)]
        var number = trimmed
        var factor = 1.0
        for unit in units where trimmed.hasSuffix(unit.suffix) {
            number = String(trimmed.dropLast(unit.suffix.count))
            factor = unit.factor
            break
        }
        guard let value = Double(number), value.isFinite, value >= 0 else {
            throw LoupeError.failed(
                "`\(text)` is not a duration. Write it as 10s, 500ms, 2m, or a plain number of seconds.")
        }
        return value * factor
    }
}
