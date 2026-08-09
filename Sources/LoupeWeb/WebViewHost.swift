import AppKit
import CryptoKit
import Foundation

// The AppKit side of `WebDriver`: the window that is never shown, the process
// policy that keeps it that way, and the per-profile data store identity.

// MARK: - Window

/// A borderless window that is created, sized, and never ordered in.
///
/// The web view has to live in *some* window: an unattached `WKWebView` renders
/// measurably differently — an earlier investigation on this machine measured 73%
/// of pixels differing between a windowed and a detached render of the same page,
/// with a max channel delta of 3/255 from gradient dithering. Invisible to the
/// eye, fatal to a byte-comparison, so the window is not optional.
///
/// `constrainFrameRect` is overridden because AppKit otherwise clamps a window to
/// the display it would appear on, and a full-page capture of a 6,000 px document
/// needs a content view taller than any screen. Verified: with the override a
/// 600×6000 content size produces a 1200×12000 px snapshot.
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Make sure AppKit in this process will never put anything on screen.
///
/// Only touched for a bare executable. A host that *is* an app bundle keeps
/// whatever policy it chose — flipping a real app to `.prohibited` would hide its
/// own windows, which is exactly the kind of disturbance this tool exists to
/// avoid. Note that a SwiftPM command-line binary already starts at
/// `.prohibited`, so in the common case nothing is changed at all (AppKit returns
/// `false` from `setActivationPolicy` when asked for the policy it already has).
@MainActor
func prepareApplicationForOffscreenUse() -> [String] {
    var notes: [String] = []
    let app = NSApplication.shared
    guard Bundle.main.bundleIdentifier == nil else {
        if app.activationPolicy() != .prohibited {
            notes.append(
                "host app runs with activation policy \(app.activationPolicy().rawValue); the web view is "
                    + "still offscreen, but this process can take focus")
        }
        return notes
    }
    if app.activationPolicy() != .prohibited, !app.setActivationPolicy(.prohibited) {
        notes.append("could not switch this process to the .prohibited activation policy")
    }
    return notes
}

// MARK: - Profiles

/// Stable per-profile data store identifier.
///
/// `WKWebsiteDataStore(forIdentifier:)` wants a UUID, and the point of a named
/// profile is that the same name comes back to the same cookies on the next run,
/// so the name is hashed into a deterministic v5-shaped UUID. Verified to work in
/// an unbundled command-line process, where it stores under the executable's own
/// WebKit container.
func websiteDataStoreIdentifier(forProfile name: String) -> UUID {
    var digest = Array(SHA256.hash(data: Data(("loupe.web.profile." + name).utf8)).prefix(16))
    digest[6] = (digest[6] & 0x0F) | 0x50  // version 5
    digest[8] = (digest[8] & 0x3F) | 0x80  // RFC 4122 variant
    let bytes = (
        digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
        digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
    )
    return UUID(uuid: bytes)
}

// MARK: - Small utilities

/// A `String` that can be read from any isolation domain.
///
/// `UIDriver.targetDescription` is a synchronous, non-isolated requirement, but
/// the current URL changes on the main actor as the driver navigates. One lock
/// around one string is the whole solution.
final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String

    init(_ value: String) { storage = value }

    var value: String {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
