import ApplicationServices
import CoreGraphics
import Foundation
import LoupeCore

extension MacDriver {
    // MARK: - Scrolling

    /// Reveal an element, preferring the app's own idea of how to do it.
    ///
    /// `AXScrollToVisible` is the action VoiceOver uses to follow focus, so an app
    /// that supports it scrolls exactly as far as it would for a real user —
    /// including inside nested scrollers, where a distance-based scroll would move
    /// the wrong one. The fallback exists because the action is widely unimplemented
    /// (a TextEdit text area offers only `AXShowMenu`), and computes the scroll-bar
    /// position from the element's own frame instead.
    func scrollTo(_ needle: String) async throws -> ActionResult {
        let (id, element) = try await resolveElement(needle)
        let name = label(of: element, fallback: id)

        if AXAPI.actions(element).contains("AXScrollToVisible") {
            let error = AXAPI.perform(element, "AXScrollToVisible")
            guard error == .success else {
                throw LoupeError.failed(
                    "AXScrollToVisible on \(name) failed: \(AXAPI.describe(error))")
            }
            return ActionResult(message: "scrolled \(name) into view (AXScrollToVisible)", payload: id)
        }

        // Work out how far the element is outside the visible area, then move the
        // enclosing scroll bar by exactly that much.
        guard let window = windowElement, let target = AXAPI.frame(element) else {
            throw LoupeError.failed("could not read the frame of \(name)")
        }
        for vertical in [true, false] {
            guard let scroller = findScroller(from: window, vertical: vertical),
                let visible = AXAPI.frame(scrollerHost(from: window, vertical: vertical) ?? window)
            else { continue }
            guard let delta = Self.distanceOutside(target, of: visible, vertical: vertical) else {
                continue
            }
            let scrollable = scroller.contentLength - scroller.visibleLength
            guard scrollable > 0.5 else { continue }
            let position = min(max(scroller.position + delta / scrollable, 0), 1)
            _ = AXAPI.set(scroller.bar, kAXValueAttribute, NSNumber(value: position))
            return ActionResult(
                message: String(
                    format:
                        "scrolled %@ into view by moving the %@ scroll bar %.3f → %.3f "
                        + "(it does not implement AXScrollToVisible)",
                    name, vertical ? "vertical" : "horizontal", scroller.position, position),
                payload: id)
        }

        throw LoupeError.unsupported(
            "\(name) does not implement AXScrollToVisible, and no enclosing scroll bar could be "
                + "positioned to reveal it. It may already be visible, or it may live in a view that "
                + "exposes no scrolling to accessibility.")
    }

    /// How far `target` sticks out of `visible` along one axis, or nil when it
    /// already fits — in which case scrolling that axis would only move the view
    /// away from where the caller is looking.
    private static func distanceOutside(_ target: Frame, of visible: Frame, vertical: Bool)
        -> Double? {
        let start = vertical ? target.y : target.x
        let end = vertical ? target.y + target.height : target.x + target.width
        let viewStart = vertical ? visible.y : visible.x
        let viewEnd = vertical ? visible.y + visible.height : visible.x + visible.width
        var delta = 0.0
        if start < viewStart { delta = start - viewStart }
        if end > viewEnd { delta = end - viewEnd }
        return delta == 0 ? nil : delta
    }

    /// Scroll the window's scroll area.
    ///
    /// Two mechanisms, because the obvious one lies. A scroll area advertises
    /// `AXScrollDownByPage` and friends in `AXUIElementCopyActionNames`, but
    /// performing one on a stock `NSScrollView` returns
    /// `AXError.attributeUnsupported` — measured on TextEdit, where all four page
    /// actions are advertised and all four fail. So the primary path is the
    /// scroll bar's own `AXValue`, a 0…1 document position that really does
    /// move; combined with the scroll area's `AXContentSize` it converts to and
    /// from points exactly. The page actions remain as a fallback for apps that
    /// implement them but expose no usable scroll bar.
    ///
    /// Never scroll-wheel events: those are delivered to the frontmost app only,
    /// which would mean taking the user's focus.
    func scroll(dx: Double, dy: Double) throws -> ActionResult {
        guard let window = windowElement else { throw LoupeError.targetNotFound(appLocator) }
        guard dx != 0 || dy != 0 else { return ActionResult(message: "no scrolling requested") }

        var performed: [String] = []
        if dy != 0 { performed.append(try scrollAxis(window, distance: dy, vertical: true)) }
        if dx != 0 { performed.append(try scrollAxis(window, distance: dx, vertical: false)) }
        return ActionResult(message: performed.joined(separator: "; "))
    }

    private func scrollAxis(_ window: AXUIElement, distance: Double, vertical: Bool) throws
        -> String {
        let axis = vertical ? "vertically" : "horizontally"
        if let scroller = findScroller(from: window, vertical: vertical) {
            return try moveScrollBar(scroller, distance: distance, axis: axis)
        }
        return try scrollByPage(window, distance: distance, vertical: vertical, axis: axis)
    }

    private func moveScrollBar(_ scroller: Scroller, distance: Double, axis: String) throws
        -> String {
        let scrollable = scroller.contentLength - scroller.visibleLength
        guard scrollable > 0.5 else {
            return "nothing to scroll \(axis): the content (\(Int(scroller.contentLength))pt) "
                + "already fits the \(Int(scroller.visibleLength))pt view"
        }
        let target = min(max(scroller.position + distance / scrollable, 0), 1)
        let error = AXAPI.set(scroller.bar, kAXValueAttribute, NSNumber(value: target))
        guard error == .success else {
            throw LoupeError.failed(
                "setting the \(axis) scroll position failed: \(AXAPI.describe(error))")
        }
        let reached =
            (AXAPI.copy(scroller.bar, kAXValueAttribute) as? NSNumber)?.doubleValue ?? target
        let moved = (reached - scroller.position) * scrollable
        return String(
            format: "scrolled %@ by %.0f points of the %.0f requested (scroll bar %.3f → %.3f of "
                + "a %.0f point range)", axis, moved, distance, scroller.position, reached, scrollable)
    }

    /// Fallback: whole-page actions, for apps that implement them.
    private func scrollByPage(
        _ window: AXUIElement, distance: Double, vertical: Bool, axis: String
    ) throws -> String {
        let action =
            vertical
            ? (distance > 0 ? "AXScrollDownByPage" : "AXScrollUpByPage")
            : (distance > 0 ? "AXScrollRightByPage" : "AXScrollLeftByPage")
        guard let (element, frame) = findPageScrollable(from: window, advertising: action) else {
            throw LoupeError.unsupported(
                "nothing under this window can scroll \(axis): no scroll bar exposes a settable "
                    + "AXValue and nothing advertises \(action). Synthetic scroll-wheel events are not "
                    + "an option — macOS delivers those to the frontmost app only, which would take "
                    + "the user's focus. Try selecting the row or cell you want so the app scrolls it "
                    + "into view itself.")
        }
        let page = vertical ? (frame?.height ?? 0) : (frame?.width ?? 0)
        let pages = page > 1 ? max(1, Int((abs(distance) / page).rounded())) : 1
        for _ in 0..<pages {
            let error = AXAPI.perform(element, action)
            guard error == .success else {
                // The action was advertised and still failed: say so plainly rather
                // than let the caller assume the window moved.
                throw LoupeError.failed(
                    "\(action) is advertised by this element but failed: \(AXAPI.describe(error)). This "
                        + "app implements neither a settable scroll bar nor its own page actions.")
            }
        }
        return String(
            format: "performed %@ %d time(s) (requested %.0f points; a page here is %.0f points)",
            action, pages, abs(distance), page)
    }

    /// A scroll area whose scroll bar can be positioned directly.
    private struct Scroller {
        let bar: AXUIElement
        /// Full length of the document along the axis, in points.
        let contentLength: Double
        /// Length of the visible part, in points.
        let visibleLength: Double
        /// Current scroll bar position, 0…1.
        let position: Double
    }

    /// Breadth-first so the outermost scroll area wins: in a nested layout the
    /// inner one is usually a detail pane, not what "scroll the window" means.
    private func findScroller(from root: AXUIElement, vertical: Bool) -> Scroller? {
        let barAttribute = vertical ? "AXVerticalScrollBar" : "AXHorizontalScrollBar"
        for element in breadthFirst(from: root, limit: 400) {
            guard let bar = AXAPI.element(element, barAttribute),
                AXAPI.isSettable(bar, kAXValueAttribute),
                let position = (AXAPI.copy(bar, kAXValueAttribute) as? NSNumber)?.doubleValue,
                let content = AXAPI.size(element, "AXContentSize"),
                let frame = AXAPI.frame(element)
            else { continue }
            return Scroller(
                bar: bar,
                contentLength: vertical ? content.height : content.width,
                visibleLength: vertical ? frame.height : frame.width,
                position: position)
        }
        return nil
    }

    /// The scroll area owning a scroll bar, for measuring the visible rectangle.
    private func scrollerHost(from root: AXUIElement, vertical: Bool) -> AXUIElement? {
        let attribute = vertical ? "AXVerticalScrollBar" : "AXHorizontalScrollBar"
        return breadthFirst(from: root, limit: 400).first { AXAPI.element($0, attribute) != nil }
    }

    private func findPageScrollable(from root: AXUIElement, advertising action: String) -> (
        AXUIElement, Frame?
    )? {
        for element in breadthFirst(from: root, limit: 400)
        where AXAPI.actions(element).contains(action) {
            return (element, AXAPI.frame(element))
        }
        return nil
    }

    private func breadthFirst(from root: AXUIElement, limit: Int) -> [AXUIElement] {
        var queue = [root]
        var visited = Set<AXKey>()
        var out: [AXUIElement] = []
        while !queue.isEmpty, out.count < limit {
            let element = queue.removeFirst()
            guard visited.insert(AXKey(element)).inserted else { continue }
            out.append(element)
            queue += AXAPI.children(element)
        }
        return out
    }
}
