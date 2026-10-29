import CoreGraphics
@testable import LoupeMedia
import Testing

@Suite struct MaxSizeTests {
    @Test func everyFormParses() throws {
        #expect(try MaxSize.parse("1280x720") == MaxSize(width: 1280, height: 720))
        #expect(try MaxSize.parse("800") == MaxSize(width: 800, height: 800, description: "800"))
        #expect(
            try MaxSize.parse("720p")
                == MaxSize(width: 1280, height: 720, followsOrientation: true, description: "720p"))
        #expect(try MaxSize.parse("1080p").width == 1920)
        #expect(try MaxSize.parse("1440p").height == 1440)
        #expect(
            try MaxSize.parse("4K")
                == MaxSize(width: 3840, height: 2160, followsOrientation: true, description: "4k"))
        #expect(try !MaxSize.parse("1280x720").followsOrientation)
    }

    @Test func badValuesAreRejectedWithTheFormsThatWork() {
        for bad in ["0", "abc", "800x", "x600", "8k", "", "-5", "0x720", "1x2x3", "12.5"] {
            #expect(throws: MediaError.self, "\(bad)") { try MaxSize.parse(bad) }
        }
        do {
            _ = try MaxSize.parse("8k")
        } catch {
            #expect(error.localizedDescription.contains("720p"))
            #expect(error.localizedDescription.contains("WxH"))
        }
    }

    @Test func landscapeAndPortraitFitInsideTheBox() throws {
        let box = try MaxSize.parse("800")
        #expect(box.fit(CGSize(width: 2560, height: 1440)) == CGSize(width: 800, height: 450))
        #expect(box.fit(CGSize(width: 1668, height: 2420)) == CGSize(width: 550, height: 800))
    }

    @Test func aPresetTurnsWithAPortraitPicture() throws {
        let preset = try MaxSize.parse("720p")
        #expect(preset.fit(CGSize(width: 2560, height: 1440)) == CGSize(width: 1280, height: 720))
        #expect(preset.fit(CGSize(width: 1440, height: 2560)) == CGSize(width: 720, height: 1280))
    }

    @Test func anExplicitBoxIsNotTurned() throws {
        let box = try MaxSize.parse("1280x720")
        #expect(box.fit(CGSize(width: 1440, height: 2560)) == CGSize(width: 404, height: 720))
    }

    @Test func nothingIsScaledUp() throws {
        let preset = try MaxSize.parse("4k")
        #expect(preset.fit(CGSize(width: 1280, height: 720)) == CGSize(width: 1280, height: 720))
        #expect(try MaxSize.parse("800").fit(CGSize(width: 800, height: 600)) == CGSize(width: 800, height: 600))
    }

    @Test func scaledSidesAreEven() throws {
        for (box, size) in [
            ("1080p", CGSize(width: 5120, height: 2879)), ("800", CGSize(width: 1667, height: 2421)),
            ("1000x333", CGSize(width: 3001, height: 999)), ("10", CGSize(width: 4000, height: 3))
        ] {
            let fitted = try MaxSize.parse(box).fit(size)
            #expect(Int(fitted.width) % 2 == 0 && Int(fitted.height) % 2 == 0, "\(box) \(size) → \(fitted)")
            #expect(fitted.width <= size.width && fitted.height <= size.height)
        }
    }
}
