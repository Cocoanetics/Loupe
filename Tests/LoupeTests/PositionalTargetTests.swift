import Testing

@testable import LoupeCore

/// `loupe press mac:Mail#0 Save` takes its first argument as the target only
/// when it reads as one; everything else stays an element.
@Suite("Positional targets")
struct PositionalTargetTests {

    @Test("a leading positional reads as a target only with a known scheme")
    func isTarget() {
        for raw in ["mac:Mail#0", "sim:booted", "web:https://x.dev", "https://x.dev", "@phone"] {
            #expect(Target.isTarget(raw), "\(raw)")
        }
        for raw in ["w0/w25/b3", "Save", "login.submit", "Name: value", "@", ""] {
            #expect(!Target.isTarget(raw), "\(raw)")
        }
    }
}
