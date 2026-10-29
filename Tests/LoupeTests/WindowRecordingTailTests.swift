import CoreMedia
@testable import LoupeMac
import Testing

@Suite struct WindowRecordingTailTests {
    @Test func aStillWindowRepeatsItsLastFrameJustBeforeTheEnd() throws {
        let held = CMTime(seconds: 4, preferredTimescale: 600)
        let tail = try #require(RecordingTail.repeatTime(last: .zero, held: held))
        #expect(abs(tail.seconds - (4.0 - 1.0 / 30)) < 0.000_1)
    }

    @Test func noRepeatWhenTheLastFrameAlreadyReachesTheEnd() {
        let held = CMTime(seconds: 4, preferredTimescale: 600)
        let justBefore = CMTimeSubtract(held, CMTime(value: 1, timescale: 30))
        #expect(RecordingTail.repeatTime(last: justBefore, held: held) == nil)
        #expect(RecordingTail.repeatTime(last: held, held: held) == nil)
    }
}
