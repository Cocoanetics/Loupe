import Foundation

extension UIAction {
    /// Parse an ordered step written as `kind:argument`.
    ///
    /// Exists so callers can express a *sequence* whose order is preserved
    /// exactly. Grouping flags by kind (all the `--set`s, then all the
    /// `--press`es) silently reorders "fill the form, then submit it" into
    /// "submit the empty form, then fill it" — which fails in a way that looks
    /// like a broken selector rather than a mis-ordered script.
    public static func parse(step raw: String) throws -> UIAction {
        guard let colon = raw.firstIndex(of: ":") else {
            throw LoupeError.failed("step '\(raw)' is missing its kind, e.g. press:Login")
        }
        let kind = String(raw[raw.startIndex..<colon]).lowercased()
        let argument = String(raw[raw.index(after: colon)...])

        // Each group returns nil for a kind it does not own. Grouping the kinds by
        // what they do — address an element, inject input, act on the target,
        // wait — keeps every branch next to the syntax notes that explain it.
        if let action = try nodeStep(kind: kind, argument: argument, raw: raw) { return action }
        if let action = try inputStep(kind: kind, argument: argument, raw: raw) { return action }
        if let action = try targetStep(kind: kind, argument: argument) { return action }
        if let action = try waitStep(kind: kind, argument: argument, raw: raw) { return action }

        throw LoupeError.failed(
            "unknown step kind '\(kind)' — use open, launch, set, press, click, type, key, "
                + "scroll, eval or wait")
    }

    /// Steps that name an element: `press:Login`, `set:Email=…`, `reveal:Footer`.
    private static func nodeStep(kind: String, argument: String, raw: String) throws -> UIAction? {
        switch kind {
            case "press": return .press(node: argument)
            case "set":
                // Split on the FIRST '=' only: values legitimately contain more.
                guard let equals = argument.firstIndex(of: "=") else {
                    throw LoupeError.failed("step '\(raw)' needs field=value")
                }
                // The selector is not expanded — an element's label can genuinely be
                // something like "$3.94".
                return .setValue(
                    node: String(argument[argument.startIndex..<equals]),
                    value: try EnvironmentInterpolation.expand(
                        String(argument[argument.index(after: equals)...])))
            case "scrollto", "reveal": return .scrollTo(node: argument)
            default: return nil
        }
    }

    /// Synthetic input: aimed at a point, or at whatever currently has focus.
    private static func inputStep(kind: String, argument: String, raw: String) throws -> UIAction? {
        switch kind {
            case "click", "cursorclick":
                return try clickStep(
                    argument: argument, raw: raw, viaCursor: kind == "cursorclick")
            case "type": return .type(try EnvironmentInterpolation.expand(argument))
            case "key": return .key(argument)
            case "scroll":
                let (dx, dy) = try numberPair(argument: argument, raw: raw)
                return .scroll(dx: dx, dy: dy)
            default: return nil
        }
    }

    /// `click:120,340` is window points; `click:px:240,680`, `click:n:0.35,0.62`
    /// and `click:screen:1500,900` name another space explicitly.
    private static func clickStep(
        argument: String, raw: String, viaCursor: Bool
    ) throws -> UIAction {
        var space = CoordinateSpace.windowPoints
        var coordinates = argument
        if let colon = argument.firstIndex(of: ":"),
            let named = CoordinateSpace.parse(String(argument[argument.startIndex..<colon])) {
            space = named
            coordinates = String(argument[argument.index(after: colon)...])
        }
        let numbers = coordinates.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard numbers.count == 2 else {
            throw LoupeError.failed(
                "step '\(raw)' needs two numbers, e.g. click:120,240 or click:n:0.5,0.33")
        }
        if space == .normalized, numbers.contains(where: { $0 < 0 || $0 > 1 }) {
            throw LoupeError.failed(
                "step '\(raw)' uses normalized coordinates, which must be between 0 and 1")
        }
        return .click(x: numbers[0], y: numbers[1], space: space, viaCursor: viaCursor)
    }

    /// Two comma-separated numbers, as `scroll:0,-400` takes.
    private static func numberPair(argument: String, raw: String) throws -> (Double, Double) {
        let numbers = argument.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        guard numbers.count == 2 else {
            throw LoupeError.failed("step '\(raw)' needs two numbers, e.g. click:120,240")
        }
        return (numbers[0], numbers[1])
    }

    /// Steps aimed at the target as a whole rather than at anything inside it.
    private static func targetStep(kind: String, argument: String) throws -> UIAction? {
        switch kind {
            case "open", "navigate":
                return .navigate(try EnvironmentInterpolation.expand(argument))
            case "launch": return .launch(argument)
            case "terminate": return .terminate(argument)
            // JavaScript is left alone: `$` is a variable name in half the web, and
            // `{}` is everywhere in it.
            case "eval": return .evaluate(argument)
            default: return nil
        }
    }

    /// Waiting, either on pixels (`wait:2`) or on elements (`await:`, `gone:`).
    private static func waitStep(kind: String, argument: String, raw: String) throws -> UIAction? {
        switch kind {
            case "wait": return .settle(timeout: Double(argument) ?? 3)
            // `await:Save` waits for it to be there and usable; `gone:Loading` waits
            // for it to vanish; `await:A|B` returns as soon as either shows up;
            // `await:Dashboard|!Invalid password` also fails fast on the error
            // instead of burning the whole timeout; `await:Save@30` overrides the
            // default timeout.
            case "await", "gone":
                let (body, timeout) = splitTimeout(argument)
                let (nodes, failures) = splitSelectors(body)
                guard !nodes.isEmpty || !failures.isEmpty else {
                    throw LoupeError.failed(
                        "step '\(raw)' needs something to wait for, e.g. await:Sign In")
                }
                return .waitFor(
                    nodes: nodes, failIf: failures, gone: kind == "gone", timeout: timeout)
            default: return nil
        }
    }

    /// Peel the optional trailing `@seconds` off an `await`/`gone` argument.
    ///
    /// Only a trailing `@` followed by a number counts, so an email address or a
    /// handle in the selector itself stays part of the selector.
    private static func splitTimeout(_ argument: String) -> (body: String, timeout: Double) {
        guard let atSign = argument.lastIndex(of: "@"),
            let seconds = Double(argument[argument.index(after: atSign)...])
        else { return (argument, 10.0) }
        return (String(argument[argument.startIndex..<atSign]), seconds)
    }

    /// Split `A|B|!Error` into what to wait for and what means "stop, this failed".
    private static func splitSelectors(_ body: String) -> (nodes: [String], failures: [String]) {
        var nodes: [String] = []
        var failures: [String] = []
        for part in body.split(separator: "|", omittingEmptySubsequences: true) {
            let candidate = part.trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty else { continue }
            if candidate.hasPrefix("!") {
                failures.append(String(candidate.dropFirst()))
            } else {
                nodes.append(candidate)
            }
        }
        return (nodes, failures)
    }
}
