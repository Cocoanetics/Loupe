import CoreGraphics
import Foundation
import LoupeCore
import Testing

@testable import LoupeKit
@testable import LoupeMCP

@Suite("Capture regions")
struct CaptureRegionTests {

    private static func png(width: Int, height: Int) throws -> Data {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try ImageOps.encode(ctx.makeImage()!)
    }

    @Test func pointRegionsPassThroughUnchanged() {
        let region = Frame(x: 10, y: 20, width: 30, height: 40)
        let options = CaptureOptions(region: region)
        #expect(options.regionInPoints(scale: 2, origin: CGPoint(x: 200, y: 150)) == region)
    }

    @Test func pixelRegionsBecomePointsFromTheCapturesOrigin() {
        // A band 380 px down a 2× window whose top-left is at screen 200,150.
        let options = CaptureOptions(
            region: Frame(x: 0, y: 380, width: 2800, height: 640), regionUnits: .pixels)
        #expect(
            options.regionInPoints(scale: 2, origin: CGPoint(x: 200, y: 150))
                == Frame(x: 200, y: 340, width: 1400, height: 320))
        #expect(CaptureOptions().regionInPoints(scale: 2) == nil)
    }

    @Test func pixelCropsAreClippedToTheImage() throws {
        let image = try Self.png(width: 100, height: 80)
        let cropped = try ImageOps.crop(image, toPixels: CGRect(x: 60, y: 50, width: 100, height: 100))
        #expect(cropped.kept == CGRect(x: 60, y: 50, width: 40, height: 30))
        let decoded = try ImageOps.decode(cropped.png)
        #expect(decoded.width == 40 && decoded.height == 30)
        #expect(throws: LoupeError.self) {
            _ = try ImageOps.crop(image, toPixels: CGRect(x: 200, y: 0, width: 10, height: 10))
        }
    }

    @Test func theAppliedCropNamesBothSpaces() {
        let crop = CaptureCrop(
            points: Frame(x: 200, y: 340, width: 1400, height: 320),
            pixels: Frame(x: 0, y: 380, width: 2800, height: 640))
        #expect(crop.note.contains("x=200 y=340 w=1400 h=320 pt"))
        #expect(crop.note.contains("x=0 y=380 w=2800 h=640 px"))
    }

    @Test func unitsAndCropsRoundTripTheWire() throws {
        let options = CaptureOptions(region: Frame(x: 1, y: 2, width: 3, height: 4), regionUnits: .pixels)
        let wire = try JSONDecoder().decode(
            LiveSession.CaptureWire.self, from: try JSONEncoder().encode(LiveSession.CaptureWire(options)))
        #expect(wire.options.regionUnits == .pixels)

        // An older peer sends no units; that has always meant points.
        let old = #"{"fullPage":false,"settle":true,"settleTimeout":3}"#
        let decoded = try JSONDecoder().decode(LiveSession.CaptureWire.self, from: Data(old.utf8))
        #expect(decoded.options.regionUnits == .points)

        let crop = CaptureCrop(
            points: Frame(x: 1, y: 2, width: 3, height: 4), pixels: Frame(x: 2, y: 4, width: 6, height: 8))
        let shot = Capture(png: Data(), pointSize: CGSize(width: 3, height: 4), scale: 2, target: "t", crop: crop)
        let back = try JSONDecoder().decode(
            LiveSession.CaptureResultWire.self,
            from: try JSONEncoder().encode(LiveSession.CaptureResultWire(shot))
        ).capture
        #expect(back.crop == crop)
    }

    @Test func toolUnitsAreStrict() throws {
        #expect(try LoupeMCPServer.regionUnits(nil) == .points)
        #expect(try LoupeMCPServer.regionUnits("Pixels") == .pixels)
        #expect(throws: LoupeError.self) { _ = try LoupeMCPServer.regionUnits("px") }
    }

    @Test func captureToolOffersRegionUnits() async {
        let capture = await LoupeTools().mcpToolMetadata.first { $0.name == "loupe_capture" }
        #expect(capture?.parameters.contains { $0.name == "regionUnits" } == true)
    }
}
