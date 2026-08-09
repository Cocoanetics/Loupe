import Foundation

// The envelope protocol the injected scripts speak, and the wire shape of a
// described element. Top-level rather than nested inside ``WebScripts`` so each
// can carry its own `CodingKeys` without a third level of nesting.

/// What every script returns. `nodes` is only populated by the describe script.
struct ScriptEnvelope: Decodable {
    var succeeded: Bool
    var code: String?
    var message: String?
    var payload: String?
    var nodes: [WireNode]?

    /// The JSON says `ok`; Swift says what it means.
    private enum CodingKeys: String, CodingKey {
        case succeeded = "ok"
        case code, message, payload, nodes
    }
}

/// Wire shape of a described element.
///
/// Deliberately a separate type from `UINode` rather than decoding straight into
/// it: the driver has to post-process (rounding, handle bookkeeping) and a wire
/// type keeps a malformed page from silently producing half-built `UINode`s.
struct WireNode: Decodable {
    var id: String
    var role: String
    var rawRole: String?
    var label: String?
    var value: String?
    var identifier: String?
    var x: Double?
    var y: Double?
    var width: Double?
    var height: Double?
    var enabled: Bool?
    var focused: Bool?
    var actions: [String]?
    var children: [WireNode]?

    /// The wire keeps the frame flat (`x`, `y`, `w`, `h`) because a nested object
    /// per node measurably inflates the JSON for a big page, and the tree is the
    /// largest thing this driver ever moves across the bridge. Swift spells the
    /// two abbreviated names out again.
    private enum CodingKeys: String, CodingKey {
        case id, role, rawRole, label, value, identifier
        case x, y
        case width = "w"
        case height = "h"
        case enabled, focused, actions, children
    }
}
