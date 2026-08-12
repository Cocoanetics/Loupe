import Foundation
import LoupeCore

// The protocol a live session speaks. Deliberately its own layer: the client
// and the server both encode against these types and nothing else, so the one
// thing that must stay in step — the shape on the wire — is in one place.
//
// Nothing here is a compatibility surface. Both ends are the same binary: a
// client that finds a session started by an older build is free to fail, and a
// session idles itself out within the quarter hour anyway. Rename fields as
// clarity demands.
extension LiveSession {

    /// One request per connection. Screenshots dwarf the connection setup, and a
    /// request/response socket needs no framing, no multiplexing and no
    /// half-open state to get wrong.
    struct Request: Codable {
        var token: String
        var verb: String
        var capture: CaptureWire?
        var describe: DescribeWire?
        var action: ActionWire?
    }

    struct Response: Codable {
        var succeeded: Bool
        var error: String?
        var capture: CaptureResultWire?
        var nodes: [UINode]?
        var action: ActionResultWire?
        var info: String?
    }

    struct CaptureWire: Codable {
        var region: Frame?
        var fullPage: Bool
        var settle: Bool
        var settleTimeout: Double

        init(_ options: CaptureOptions) {
            region = options.region
            fullPage = options.fullPage
            settle = options.settle
            settleTimeout = options.settleTimeout
        }
        var options: CaptureOptions {
            CaptureOptions(
                region: region, fullPage: fullPage, settle: settle, settleTimeout: settleTimeout)
        }
    }

    struct DescribeWire: Codable {
        var maxDepth: Int
        var interestingOnly: Bool
        var filter: String?
        // Optional so an older peer's payload still decodes; absent means the
        // pre-disclosure defaults. Miss these two and a session-driven describe
        // silently degrades to the full tree — no error anywhere, just the old
        // 20k-token answer back, in the mode long agent loops actually use.
        var scope: DescribeOptions.Scope?
        var root: String?

        init(_ options: DescribeOptions) {
            maxDepth = options.maxDepth
            interestingOnly = options.interestingOnly
            filter = options.filter
            scope = options.scope
            root = options.root
        }
        var options: DescribeOptions {
            DescribeOptions(
                maxDepth: maxDepth, interestingOnly: interestingOnly, filter: filter,
                scope: scope ?? .all, root: root)
        }
    }

    struct CaptureResultWire: Codable {
        var pngBase64: String
        var width: Double
        var height: Double
        var scale: Double
        var target: String
        var notes: [String]

        init(_ shot: Capture) {
            pngBase64 = shot.png.base64EncodedString()
            width = shot.pointSize.width
            height = shot.pointSize.height
            scale = shot.scale
            target = shot.target
            notes = shot.notes
        }
        var capture: Capture {
            Capture(
                png: Data(base64Encoded: pngBase64) ?? Data(),
                pointSize: CGSize(width: width, height: height),
                scale: scale, target: target, notes: notes)
        }
    }

    struct ActionResultWire: Codable {
        var succeeded: Bool
        var message: String
        var payload: String?

        init(_ result: ActionResult) {
            succeeded = result.ok
            message = result.message
            payload = result.payload
        }
        var result: ActionResult {
            ActionResult(ok: succeeded, message: message, payload: payload)
        }
    }

    /// `UIAction` carries associated values, so it travels as a tagged record
    /// rather than relying on synthesized enum coding, which would bake the case
    /// layout into the wire format.
    struct ActionWire: Codable {
        var kind: String
        var node: String?
        var text: String?
        var x: Double?
        var y: Double?
        var timeout: Double?

        init(_ action: UIAction) {
            switch action {
                case .press(let target):
                    kind = "press"
                    node = target
                case .scrollTo(let target):
                    kind = "scrollto"
                    node = target
                case .setValue(let target, let value):
                    kind = "setValue"
                    node = target
                    text = value
                case .click(let pointX, let pointY, let space, let viaCursor):
                    kind = viaCursor ? "cursorclick" : "click"
                    x = pointX
                    y = pointY
                    text = space.rawValue
                case .scroll(let deltaX, let deltaY):
                    kind = "scroll"
                    x = deltaX
                    y = deltaY
                case .settle(let seconds):
                    kind = "settle"
                    timeout = seconds
                case .waitFor(let nodes, let failures, let gone, let seconds):
                    kind = gone ? "gone" : "await"
                    node = nodes.joined(separator: "|")
                    text = failures.joined(separator: "|")
                    timeout = seconds
                // Six verbs, one shape: the whole payload is a single string and
                // only the name differs, so they share a branch rather than six
                // near-identical ones.
                case .type(let payload), .key(let payload), .navigate(let payload),
                    .evaluate(let payload), .launch(let payload), .terminate(let payload):
                    kind = Self.textVerbName(for: action)
                    text = payload
            }
        }

        /// The wire name of a verb whose entire payload is one string.
        ///
        /// Exhaustiveness still lives in `init(_:)` above — that is the switch the
        /// compiler makes you extend when a ``UIAction`` case is added — so this
        /// one can afford a default. An unnamed verb decodes back to nil on the
        /// far side, which surfaces as "unrecognized action" rather than a
        /// silently wrong one.
        private static func textVerbName(for action: UIAction) -> String {
            switch action {
                case .type: return "type"
                case .key: return "key"
                case .navigate: return "navigate"
                case .evaluate: return "evaluate"
                case .launch: return "launch"
                case .terminate: return "terminate"
                default: return ""
            }
        }

        var action: UIAction? {
            switch kind {
                case "press": return node.map { .press(node: $0) }
                case "scrollto": return node.map { .scrollTo(node: $0) }
                case "setValue":
                    guard let node, let text else { return nil }
                    return .setValue(node: node, value: text)
                case "click", "cursorclick":
                    guard let x, let y else { return nil }
                    return .click(
                        x: x, y: y,
                        space: text.flatMap { CoordinateSpace(rawValue: $0) } ?? .windowPoints,
                        viaCursor: kind == "cursorclick")
                case "type": return text.map { .type($0) }
                case "key": return text.map { .key($0) }
                case "scroll":
                    guard let x, let y else { return nil }
                    return .scroll(dx: x, dy: y)
                case "navigate": return text.map { .navigate($0) }
                case "evaluate": return text.map { .evaluate($0) }
                case "launch": return text.map { .launch($0) }
                case "terminate": return text.map { .terminate($0) }
                case "settle": return .settle(timeout: timeout ?? 3)
                case "await", "gone":
                    let nodes = (node ?? "").split(separator: "|").map(String.init)
                    let failures = (text ?? "").split(separator: "|").map(String.init)
                    guard !nodes.isEmpty || !failures.isEmpty else { return nil }
                    return .waitFor(
                        nodes: nodes, failIf: failures, gone: kind == "gone", timeout: timeout ?? 10)
                default: return nil
            }
        }
    }
}
