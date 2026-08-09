import Foundation

/// `{{NAME}}` interpolation for action values.
///
/// Exists for secrets. Writing `--step 'set:password={{PORTAL_PASSWORD}}'` keeps
/// the value out of `argv`, where `ps` shows it to every process on the machine
/// and the shell writes it to history — and, when an agent is driving, out of the
/// transcript too. The caller passes the *name*; only this process sees the value.
///
/// Two deliberate choices:
///
/// **No `$`.** `$NAME` and `{$NAME}` both look natural, but the shell expands
/// them before Loupe is even started unless every value is single-quoted, so the
/// secret lands in `argv` anyway — the exact problem this solves. Braces alone
/// survive every quoting style. They also cannot be confused with the two things
/// this tool handles constantly: currency (`$3.94`) and JavaScript (`$`).
///
/// **A missing variable is an error, not a passthrough.** Leaving `{{NAME}}`
/// in place would type it into the field, the login would fail, and the failure
/// would look like a bad selector or a broken form — anything except the missing
/// variable that actually caused it. Say so instead. When a value really is
/// optional, `{{NAME:-fallback}}` states that intent explicitly.
public enum EnvironmentInterpolation {

    /// Every value this process has substituted from the environment.
    ///
    /// Interpolation keeps a secret out of `argv`, but drivers echo what they did
    /// — "set <input#password> to …" — and on the MCP path that message goes
    /// straight into the agent's transcript. Protecting the input and then
    /// printing the value would be theatre, so anything substituted here is
    /// remembered and scrubbed from output by ``Secrets/redact(_:)``.
    static let substituted = SecretRegistry()

    /// A reference is `{{IDENT}}` or `{{IDENT:-default}}`, `IDENT` being a shell
    /// variable name. Anything else — `{{ }}`, `{{a-b}}`, a lone `{` — is ordinary
    /// text and passes through untouched, so values containing braces are safe.
    /// A preceding backslash escapes the whole reference.
    private static let patternSource = #"(\\)?\{\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}\}"#

    /// Compiled once, from a literal that cannot vary at runtime.
    ///
    /// A failure here is therefore a typo in `patternSource`, never anything the
    /// caller did — so trap on the spot and name the pattern, rather than letting
    /// it surface later as an inexplicable interpolation failure on whatever
    /// `{{NAME}}` a user happened to write first.
    private static let pattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: Self.patternSource)
        } catch {
            preconditionFailure(
                "Loupe interpolation pattern failed to compile: \(Self.patternSource) — \(error)")
        }
    }()

    /// Substitute `{{NAME}}` references from the environment.
    ///
    /// - Throws: ``LoupeError/failed(_:)`` naming the variable when it is unset or
    ///   empty and no default was given. Empty counts as missing on purpose: an
    ///   empty password or username is never the intent, and `{{NAME:-}}` says
    ///   "blank really is fine" when it is.
    public static func expand(
        _ input: String, environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        let full = NSRange(input.startIndex..<input.endIndex, in: input)
        let matches = pattern.matches(in: input, range: full)
        guard !matches.isEmpty else { return input }

        var out = ""
        var cursor = input.startIndex
        for match in matches {
            guard let whole = Range(match.range, in: input) else { continue }
            out += input[cursor..<whole.lowerBound]
            cursor = whole.upperBound

            // `\{{NAME}}` is a literal: emit it without the backslash.
            if match.range(at: 1).location != NSNotFound {
                out += input[input.index(whole.lowerBound, offsetBy: 1)..<whole.upperBound]
                continue
            }

            guard let nameRange = Range(match.range(at: 2), in: input) else { continue }
            let name = String(input[nameRange])
            let fallback = Range(match.range(at: 3), in: input).map { String(input[$0]) }
            let value = environment[name]

            if let value, !value.isEmpty {
                Self.substituted.remember(value)
                out += value
            } else if let fallback {
                out += fallback
            } else {
                let why = value == nil ? "is not set" : "is set but empty"
                throw LoupeError.failed(
                    """
                    environment variable \(name) \(why), referenced as {{\(name)}}.
                      Export it first — its value is read here and never appears in the command line.
                      If blank is genuinely acceptable, write {{\(name):-}} to say so, or \
                    {{\(name):-some default}} to supply a fallback.
                    """)
            }
        }
        out += input[cursor...]
        return out
    }
}

/// Thread-safe set of values that must never appear in output.
final class SecretRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var values: Set<String> = []

    func remember(_ value: String) {
        // Very short values would redact half the page; a secret worth hiding is
        // longer than this, and over-redacting makes output useless.
        guard value.count >= 4 else { return }
        lock.lock()
        values.insert(value)
        lock.unlock()
    }

    func all() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// Scrubbing for anything Loupe prints or returns.
public enum Secrets {
    /// Replace any value that came from `{{NAME}}` interpolation with a mask.
    ///
    /// Applied to every message, payload and error on the way out. Cheap, and it
    /// closes the gap between "the secret is not in the command line" and "the
    /// secret is not anywhere the user or an agent can read it".
    public static func redact(_ text: String) -> String {
        var out = text
        // Longest first, so a secret containing another is masked whole.
        for value in EnvironmentInterpolation.substituted.all().sorted(by: { $0.count > $1.count }) {
            out = out.replacingOccurrences(of: value, with: "••••")
        }
        return out
    }
}
