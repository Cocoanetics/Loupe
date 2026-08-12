import Foundation
import Testing

@testable import LoupeKit

@Suite("Doctor reports something a caller can act on")
struct DiagnosticsTests {

    /// The whole point of the structure: a caller decides from `grant`, not by
    /// reading remedy prose written for someone at a terminal.
    @Test("missing grants are listed, satisfied ones are not")
    func missingGrantsAreExtracted() {
        let report = Diagnostics.Report(
            surfaces: [
                Diagnostics.Surface(
                    name: "Mac apps",
                    checks: [
                        Diagnostics.Check(
                            name: "Accessibility", ok: false, warningOnly: false,
                            remedy: "grant it", grant: .accessibility),
                        Diagnostics.Check(
                            name: "Screen Recording", ok: true, warningOnly: false,
                            remedy: nil, grant: .screenRecording),
                        Diagnostics.Check(
                            name: "screen is unlocked", ok: false, warningOnly: true,
                            remedy: "unlock", grant: nil)
                    ])
            ],
            lines: [], allGood: false)
        #expect(report.missingGrants == [.accessibility])
    }

    @Test("a warning does not make a surface unusable")
    func warningsDoNotFailASurface() {
        let surface = Diagnostics.Surface(
            name: "Mac apps",
            checks: [
                Diagnostics.Check(
                    name: "ok thing", ok: true, warningOnly: false, remedy: nil, grant: nil),
                Diagnostics.Check(
                    name: "screen is unlocked", ok: false, warningOnly: true, remedy: "unlock",
                    grant: nil)
            ])
        #expect(surface.ok)
    }

    /// Hard-won: Accessibility takes effect at once, Screen Recording is read at
    /// process start. Not knowing that reads as "the grant did not work".
    @Test("only accessibility reaches a process that is already running")
    func grantsDifferInWhenTheyApply() {
        #expect(Diagnostics.Grant.accessibility.appliesToRunningProcess)
        #expect(!Diagnostics.Grant.screenRecording.appliesToRunningProcess)
    }

    @Test("every grant names the pane that changes it")
    func everyGrantHasSomewhereToGo() {
        for grant in Diagnostics.Grant.allCases {
            #expect(grant.settingsURL.hasPrefix("x-apple.systempreferences:"))
        }
    }

    /// The MCP tool parses its argument as a raw value, so these names are API.
    @Test("grant names round-trip", arguments: Diagnostics.Grant.allCases)
    func grantNamesRoundTrip(_ grant: Diagnostics.Grant) {
        #expect(Diagnostics.Grant(rawValue: grant.rawValue) == grant)
    }

    @Test("the report encodes for a caller that reads JSON")
    func reportEncodes() throws {
        let report = Diagnostics.Report(
            surfaces: [
                Diagnostics.Surface(
                    name: "Web",
                    checks: [
                        Diagnostics.Check(
                            name: "WebKit", ok: true, warningOnly: false, remedy: nil, grant: nil)
                    ])
            ],
            lines: ["Web", "✓ WebKit"], allGood: true)
        let decoded = try JSONDecoder().decode(
            Diagnostics.Report.self, from: try JSONEncoder().encode(report))
        #expect(decoded.allGood)
        #expect(decoded.surfaces.first?.checks.first?.name == "WebKit")
        #expect(decoded.lines.count == 2)
    }
}
