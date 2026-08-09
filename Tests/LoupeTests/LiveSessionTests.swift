import Foundation
import Testing

@testable import LoupeCore
@testable import LoupeKit

@Suite("Live sessions")
struct LiveSessionTests {

    @Test("@name parses as a live target and round-trips")
    func parsing() throws {
        let target = try Target.parse("@portal")
        #expect(target.surface == .live)
        #expect(target.locator == "portal")
        #expect(target.description == "@portal")
    }

    @Test("a bare @ is rejected")
    func bareAt() {
        #expect(throws: LoupeError.self) { try Target.parse("@") }
    }

    @Test("descriptors survive a save/load round trip")
    func descriptorRoundTrip() throws {
        // This is the regression that mattered: `save` encoded dates as ISO-8601
        // while `load` used a default decoder, so every read failed silently and a
        // running session looked like it had never started.
        let descriptor = LiveSession.Descriptor(
            name: "test-\(UUID().uuidString.prefix(8))", target: "web:https://x.dev",
            port: 51234, token: "t0ken", pid: ProcessInfo.processInfo.processIdentifier)
        try LiveSession.save(descriptor)
        defer { LiveSession.remove(descriptor.name) }

        let loaded = try LiveSession.load(descriptor.name)
        #expect(loaded.port == 51234)
        #expect(loaded.token == "t0ken")
        #expect(loaded.target == "web:https://x.dev")
        #expect(abs(loaded.startedAt.timeIntervalSince(descriptor.startedAt)) < 1)
    }

    @Test("a session whose process is gone is not returned")
    func deadSessionIsSwept() throws {
        let name = "dead-\(UUID().uuidString.prefix(8))"
        // pid 1 is launchd, which we can signal-probe but never own; use an
        // implausible pid instead so `kill(pid, 0)` genuinely fails.
        let descriptor = LiveSession.Descriptor(
            name: name, target: "web:https://x.dev", port: 1, token: "t", pid: 999_999)
        try LiveSession.save(descriptor)
        defer { LiveSession.remove(name) }
        #expect(!descriptor.isAlive)
        #expect(throws: LoupeError.self) { _ = try LiveSession.load(name) }
    }
}

@Suite("Ordered steps")
struct StepTests {

    @Test("steps keep the order they were written in")
    func order() throws {
        // The bug this prevents: pressing Login before setting the fields submits
        // an empty form, and the failure looks like a broken selector.
        let raw = ["set:username=oliver", "set:password=hunter2", "press:Login"]
        let actions = try raw.map(UIAction.parse(step:))
        guard case .setValue(let firstField, let firstValue) = actions[0] else {
            Issue.record("not setValue"); return
        }
        guard case .setValue(let secondField, _) = actions[1] else {
            Issue.record("not setValue"); return
        }
        guard case .press(let pressed) = actions[2] else { Issue.record("not press"); return }
        #expect(firstField == "username")
        #expect(firstValue == "oliver")
        #expect(secondField == "password")
        #expect(pressed == "Login")
    }

    @Test("a value containing = survives")
    func equalsInValue() throws {
        guard case .setValue(_, let value) = try UIAction.parse(step: "set:token=a=b=c") else {
            Issue.record("not setValue"); return
        }
        #expect(value == "a=b=c")
    }

    @Test("malformed steps are rejected with guidance")
    func malformed() {
        #expect(throws: (any Error).self) { try UIAction.parse(step: "press") }
        #expect(throws: (any Error).self) { try UIAction.parse(step: "frobnicate:x") }
        #expect(throws: (any Error).self) { try UIAction.parse(step: "click:12") }
    }
}

@Suite("Environment interpolation")
struct EnvironmentTests {
    let env = ["PORTAL_PASSWORD": "s3cret", "EMPTY": "", "USERID": "oliver"]

    @Test("substitutes a set variable")
    func substitutes() throws {
        #expect(try EnvironmentInterpolation.expand("{{USERID}}", environment: env) == "oliver")
        #expect(
            try EnvironmentInterpolation.expand("user={{USERID}}!", environment: env) == "user=oliver!")
    }

    @Test("several references in one value")
    func several() throws {
        #expect(
            try EnvironmentInterpolation.expand("{{USERID}}:{{PORTAL_PASSWORD}}", environment: env)
                == "oliver:s3cret")
    }

    @Test("currency is never mistaken for a reference")
    func currencyIsSafe() throws {
        // The whole reason for braces over `$`: this tool exists to check totals.
        for value in ["$3.94", "Total: $3.88", "$USERID", "{$USERID}"] {
            #expect(try EnvironmentInterpolation.expand(value, environment: env) == value)
        }
    }

    @Test("ordinary braces pass through")
    func bracesAreSafe() throws {
        for value in ["{\"a\":1}", "{{ }}", "{{a-b}}", "{x}", "}}{{"] {
            #expect(try EnvironmentInterpolation.expand(value, environment: env) == value)
        }
    }

    @Test("a missing variable is an error, never a passthrough")
    func missingThrows() {
        // Substituting the literal would type "{{NOPE}}" into the field, and the
        // resulting failure would look like anything but a missing variable.
        #expect(throws: LoupeError.self) {
            try EnvironmentInterpolation.expand("{{NOPE}}", environment: env)
        }
    }

    @Test("set-but-empty counts as missing")
    func emptyThrows() {
        #expect(throws: LoupeError.self) {
            try EnvironmentInterpolation.expand("{{EMPTY}}", environment: env)
        }
    }

    @Test("defaults cover the genuinely optional case")
    func defaults() throws {
        #expect(try EnvironmentInterpolation.expand("{{NOPE:-anon}}", environment: env) == "anon")
        #expect(try EnvironmentInterpolation.expand("{{EMPTY:-anon}}", environment: env) == "anon")
        #expect(try EnvironmentInterpolation.expand("{{USERID:-anon}}", environment: env) == "oliver")
        // An explicit empty default is how you say "blank really is fine".
        #expect(try EnvironmentInterpolation.expand("{{NOPE:-}}", environment: env) == "")
    }

    @Test("a backslash escapes a reference")
    func escaping() throws {
        #expect(try EnvironmentInterpolation.expand("\\{{USERID}}", environment: env) == "{{USERID}}")
    }

    @Test("the error names the variable and how to fix it")
    func errorIsActionable() {
        do {
            _ = try EnvironmentInterpolation.expand("{{PORTAL_TOKEN}}", environment: env)
            Issue.record("should have thrown")
        } catch {
            let text = (error as? LoupeError)?.errorDescription ?? "\(error)"
            #expect(text.contains("PORTAL_TOKEN"))
            #expect(text.contains(":-"))
        }
    }

    @Test("steps interpolate values but not selectors or JavaScript")
    func appliedInTheRightPlaces() throws {
        // A selector can legitimately be a label like "$3.94" or contain braces,
        // and `{}` is everywhere in JavaScript.
        guard case .setValue(let node, _) = try UIAction.parse(step: "set:{{USERID}}=x") else {
            Issue.record("not setValue"); return
        }
        #expect(node == "{{USERID}}")

        guard case .evaluate(let script) = try UIAction.parse(step: "eval:const o = {{a:1}}") else {
            Issue.record("not evaluate"); return
        }
        #expect(script == "const o = {{a:1}}")
    }
}

@Suite("Secret redaction")
struct RedactionTests {
    @Test("an interpolated value never survives into output")
    func redacts() throws {
        let env = ["TEST_SECRET_VALUE": "hunter2-abcdef"]
        _ = try EnvironmentInterpolation.expand("{{TEST_SECRET_VALUE}}", environment: env)
        // Protecting argv and then printing the value would be theatre.
        let message = "set <input#password> to \"hunter2-abcdef\" and fired input"
        #expect(!Secrets.redact(message).contains("hunter2-abcdef"))
        #expect(Secrets.redact(message).contains("••••"))
    }

    @Test("very short values are not redacted")
    func shortValuesPassThrough() throws {
        // Masking a 2-character value would blank out unrelated text everywhere.
        let env = ["TEST_TINY": "ab"]
        _ = try EnvironmentInterpolation.expand("{{TEST_TINY}}", environment: env)
        #expect(Secrets.redact("a label about abstraction") == "a label about abstraction")
    }
}

@Suite("Waiting")
struct WaitTests {
    @Test("await parses one or several candidates")
    func candidates() throws {
        guard case .waitFor(let nodes, let failIf, let gone, let timeout) =
            try UIAction.parse(step: "await:Dashboard")
        else { Issue.record("not waitFor"); return }
        #expect(nodes == ["Dashboard"])
        #expect(failIf.isEmpty)
        #expect(!gone)
        #expect(timeout == 10)
    }

    @Test("failure candidates are marked with !")
    func failures() throws {
        // The point: a wrong password should fail in the time the app takes to
        // reject it, not after the full timeout, and should say what it saw.
        guard case .waitFor(let nodes, let failIf, _, let timeout) =
            try UIAction.parse(step: "await:Health Dashboard|!Invalid|!failed@25")
        else { Issue.record("not waitFor"); return }
        #expect(nodes == ["Health Dashboard"])
        #expect(failIf == ["Invalid", "failed"])
        #expect(timeout == 25)
    }

    @Test("gone waits for disappearance")
    func gone() throws {
        guard case .waitFor(let nodes, _, let gone, _) = try UIAction.parse(step: "gone:Spinner")
        else { Issue.record("not waitFor"); return }
        #expect(nodes == ["Spinner"])
        #expect(gone)
    }

    @Test("a wait with nothing to wait for is rejected")
    func empty() {
        #expect(throws: (any Error).self) { try UIAction.parse(step: "await:") }
    }
}

@Suite("Scrolling")
struct ScrollTests {
    @Test("scrollto names an element to reveal")
    func scrollTo() throws {
        guard case .scrollTo(let node) = try UIAction.parse(step: "scrollto:Save") else {
            Issue.record("not scrollTo"); return
        }
        #expect(node == "Save")
    }

    @Test("reveal is an alias")
    func revealAlias() throws {
        guard case .scrollTo(let node) = try UIAction.parse(step: "reveal:w0/g1/b3") else {
            Issue.record("not scrollTo"); return
        }
        #expect(node == "w0/g1/b3")
    }

    @Test("scroll still takes a distance")
    func distance() throws {
        guard case .scroll(let dx, let dy) = try UIAction.parse(step: "scroll:0,-400") else {
            Issue.record("not scroll"); return
        }
        #expect(dx == 0)
        #expect(dy == -400)
    }
}

@Suite("Current target")
struct CurrentTargetTests {
    /// Its own store per test: swift-testing runs suites in parallel, and these
    /// would otherwise fight each other — and clobber whatever target the user
    /// has set in their own shell.
    let store = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("loupe-current-\(UUID().uuidString).json")

    @Test("an explicit target always wins over the remembered one")
    func explicitWins() throws {
        try CurrentTarget.save(CurrentTarget(target: "mac:Safari"), to: store)
        defer { CurrentTarget.clear(at: store) }
        #expect(try CurrentTarget.resolve("sim:booted", storeURL: store).surface == .sim)
        #expect(try CurrentTarget.resolve(nil, storeURL: store).surface == .mac)
    }

    @Test("with nothing set, the error names both ways to fix it")
    func helpfulWhenUnset() throws {
        CurrentTarget.clear(at: store)
        do {
            _ = try CurrentTarget.resolve(nil, storeURL: store)
            Issue.record("should have thrown")
        } catch {
            let text = (error as? LoupeError)?.errorDescription ?? "\(error)"
            #expect(text.contains("loupe use"))
        }
    }

    @Test("viewport and profile travel with the target")
    func carriesOptions() throws {
        try CurrentTarget.save(
            CurrentTarget(target: "web:https://x.dev", viewport: "800x600", profile: "work"),
            to: store)
        defer { CurrentTarget.clear(at: store) }
        let loaded = try #require(CurrentTarget.load(from: store))
        #expect(loaded.viewport == "800x600")
        #expect(loaded.profile == "work")
    }
}

@Suite("Session naming")
struct SessionNamingTests {
    @Test("web targets are named after the host or the file, not the whole URL")
    func webNames() throws {
        // Slugifying the locator gives `file----tmp-lp-login-html`, which is what
        // you would then have to type to close it.
        #expect(LiveSession.suggestedName(for: try Target.parse("file:///tmp/lp/login.html")) == "login")
        #expect(LiveSession.suggestedName(for: try Target.parse("https://example.com/a/b")) == "example-com")
    }

    @Test("mac and simulator targets keep their own names")
    func otherSurfaces() throws {
        #expect(LiveSession.suggestedName(for: try Target.parse("mac:My App")) == "my-app")
        #expect(LiveSession.suggestedName(for: try Target.parse("sim:iPhone 17 Pro")) == "iphone-17-pro")
    }

    @Test("a target with nothing usable still yields a name")
    func fallback() throws {
        #expect(!LiveSession.suggestedName(for: try Target.parse("mac:---")).isEmpty)
    }
}
