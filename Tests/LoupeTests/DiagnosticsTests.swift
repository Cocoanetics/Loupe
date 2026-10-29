import Foundation
import Testing

@testable import LoupeCore
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
            lines: [], allGood: false, requested: nil)
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

    /// The Codex review caught this: with `--request` the prose lines were
    /// printed before the JSON, so stdout would not parse. Everything the run
    /// produced has to be inside the one object.
    @Test("a requested grant travels inside the report, not beside it")
    func requestedGrantsRideAlongInJSON() throws {
        var report = Diagnostics.Report(surfaces: [], lines: [], allGood: true, requested: nil)
        report.requested = [
            Diagnostics.AccessResult(
                grant: .screenRecording, grantedBefore: false, grantedNow: false,
                settingsURL: Diagnostics.Grant.screenRecording.settingsURL, note: "asked.")
        ]
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(Diagnostics.Report.self, from: data)
        #expect(decoded.requested?.count == 1)
        #expect(decoded.requested?.first?.grant == .screenRecording)
        // The whole payload is one JSON value — nothing printed alongside it.
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
    }

    /// Also from review: both APIs report authorization, never whether a dialog
    /// was drawn, so a `promptShown` field could only ever have been guessed —
    /// and the obvious guess is wrong exactly when a grant was already denied.
    @Test("an access result claims only what can be observed")
    func accessResultDoesNotClaimPromptVisibility() throws {
        let result = Diagnostics.AccessResult(
            grant: .accessibility, grantedBefore: false, grantedNow: false,
            settingsURL: Diagnostics.Grant.accessibility.settingsURL, note: "asked.")
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(result)) as? [String: Any]
        #expect(json?["promptShown"] == nil)
        #expect(json?["grantedNow"] as? Bool == false)
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
            lines: ["Web", "✓ WebKit"], allGood: true, requested: nil)
        let decoded = try JSONDecoder().decode(
            Diagnostics.Report.self, from: try JSONEncoder().encode(report))
        #expect(decoded.allGood)
        #expect(decoded.surfaces.first?.checks.first?.name == "WebKit")
        #expect(decoded.lines.count == 2)
    }
}

@Suite("Grants are named after the app macOS charges them to")
struct PrivacyAttributionTests {

    /// Today's prompt: `loupe` run from Claude Code's shell was charged to
    /// Claude Code's own bundle, not to the loupe binary.
    @Test("a CLI under an app is attributed to the nearest app above it")
    func cliUnderAnAppIsChargedToThatApp() {
        let client = PrivacyAttribution.attribute(chain: [
            "/Volumes/SSD/SwiftPM/Loupe-test/out/Products/Release/loupe",
            "/bin/zsh",
            "/Users/me/Library/Application Support/Claude/claude-code/2.1.309/x/claude.app/Contents/MacOS/claude",
            "/Applications/Claude.app/Contents/MacOS/Claude"
        ])
        #expect(client.path.hasSuffix("/claude-code/2.1.309/x/claude.app"))
        #expect(!client.isSelf)
        #expect(client.settingsEntry.contains(client.path))
    }

    /// The daemon MissionControl installs runs from /opt/homebrew/bin under
    /// launchd: no app above it, so the grant is its own.
    @Test("a launchd daemon with no app above it is its own client")
    func bareDaemonIsItsOwnClient() {
        let client = PrivacyAttribution.attribute(chain: ["/opt/homebrew/bin/missioncontrold"])
        #expect(client.isSelf)
        #expect(client.path == "/opt/homebrew/bin/missioncontrold")
        #expect(client.name == "missioncontrold")
        #expect(client.settingsEntry == "/opt/homebrew/bin/missioncontrold")
    }

    @Test("a helper inside an app bundle belongs to that bundle")
    func helperInsideBundle() {
        let client = PrivacyAttribution.attribute(chain: [
            "/Applications/MissionControl.app/Contents/MacOS/missioncontrold",
            "/Applications/MissionControl.app/Contents/MacOS/MissionControl"
        ])
        #expect(client.path == "/Applications/MissionControl.app")
        #expect(client.isSelf)
    }

    @Test("the Screen Recording remedy and note name the client, not loupe")
    func remedyNamesTheClient() {
        let client = PrivacyAttribution.Client(
            name: "Terminal", path: "/System/Applications/Utilities/Terminal.app", isSelf: false)
        #expect(Diagnostics.screenRecordingRemedy(client).contains("Terminal (/System/Applications"))
        let note = Diagnostics.screenRecordingNote(client)
        #expect(note.contains("Terminal"))
        #expect(note.contains("does not block"))
    }

    /// A note is information that is true either way, so it shows on a passing
    /// check too — that is what turns the monthly alert from a surprise into
    /// something `doctor` already said.
    @Test("a note renders on a passing check; a remedy only on a failing one")
    func notesRenderEvenWhenOK() {
        let lines = Diagnostics.render([
            Diagnostics.Surface(
                name: "Mac apps",
                checks: [
                    Diagnostics.Check(
                        name: "Screen Recording", ok: true, remedy: "grant it",
                        grant: .screenRecording, note: "charged to Terminal")
                ])
        ])
        #expect(lines == ["Mac apps", "✓ Screen Recording", "    · charged to Terminal"])
    }

    /// `LoupeHost` decodes a hosted doctor's JSON; an older host sends neither
    /// `attributedTo` nor `note`.
    @Test("a report from an older host still decodes")
    func olderReportDecodes() throws {
        let json = #"""
            {"surfaces":[{"name":"Mac","checks":[{"name":"x","ok":true,"warningOnly":false}]}],
             "lines":[],"allGood":true}
            """#
        let report = try JSONDecoder().decode(Diagnostics.Report.self, from: Data(json.utf8))
        #expect(report.attributedTo == nil)
        #expect(report.surfaces.first?.checks.first?.note == nil)
    }
}
