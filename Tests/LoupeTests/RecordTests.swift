import CoreGraphics
import Foundation
import ImageIO
import LoupeCore
import LoupeMedia
import Testing

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

    @Test func identicalFramesCollapseIntoOneLongHold() {
        let held = FrameCollapser.collapse(
            frames([10, 10, 10, 10, 200]), endTime: 0.5, threshold: 0.002)
        #expect(held.count == 2)
        #expect(abs(held[0].delay - 0.4) < 0.001)
        #expect(abs(held[1].delay - 0.1) < 0.001)
    }

    @Test func slowDriftIsComparedAgainstTheLastKeptFrame() {
        // Each step is 1/255 apart (0.4%) but the threshold is 1%: comparing
        // neighbours would keep one frame, comparing to the kept frame keeps more.
        let held = FrameCollapser.collapse(
            frames([100, 101, 102, 103, 104, 105]), endTime: 0.6, threshold: 0.01)
        #expect(held.count > 1)
        #expect(abs(held.map(\.delay).reduce(0, +) - 0.6) < 0.001)
    }

    @Test func delaysAreClamped() {
        let held = FrameCollapser.collapse(
            [TimedFrame(image: solid(0), time: 0), TimedFrame(image: solid(255), time: 0.001)],
            endTime: 0.002, threshold: 0.002)
        #expect(held.allSatisfy { $0.delay >= FrameCollapser.minDelay })
        let long = FrameCollapser.collapse(frames([5]), endTime: 5000, threshold: 0.002)
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
}
