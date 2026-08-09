import Foundation

// Verbs that act on the page as a whole: scrolling, the readiness probe, and
// the `evaluate` fallback.

extension WebScripts {
    /// Bring an element into view without pressing it — the web equivalent of
    /// `AXScrollToVisible`, and the same call the press preflight already makes.
    static func scrollIntoView(handle: String) -> String {
        wrap(
            #"""
            var ID = \#(literal(handle));
            var hit = L.find(ID);
            if (!hit) {
                return L.err("nodeNotFound",
                    "no element carries handle '" + ID + "' any more — describe again for a fresh one.");
            }
            var el = hit.el;
            var before = { x: window.scrollX, y: window.scrollY };
            try { el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" }); }
            catch (e) { el.scrollIntoView(true); }
            var r = el.getBoundingClientRect();
            var visible = r.bottom > 0 && r.top < window.innerHeight
                && r.right > 0 && r.left < window.innerWidth;
            if (!visible) {
                return L.err("failed",
                    L.desc(el) + " is still outside the viewport after scrollIntoView; it may sit in a "
                    + "clipped container, or be hidden.");
            }
            return L.ok("revealed " + L.desc(el) + "; page scrolled from (" + Math.round(before.x) + ", "
                + Math.round(before.y) + ") to (" + Math.round(window.scrollX) + ", "
                + Math.round(window.scrollY) + ")",
                { payload: JSON.stringify({ x: Math.round(r.left), y: Math.round(r.top) }) });
            """#)
    }

    /// Scroll the window, reporting how far it actually moved.
    static func scroll(dx: Double, dy: Double) -> String {
        wrap(
            #"""
            var DX = \#(dx), DY = \#(dy);
            var x0 = window.scrollX, y0 = window.scrollY;
            try { window.scrollBy({ left: DX, top: DY, behavior: "instant" }); }
            catch (e) { window.scrollBy(DX, DY); }
            var x1 = window.scrollX, y1 = window.scrollY;
            var maxY = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
            var maxX = Math.max(0, document.documentElement.scrollWidth - window.innerWidth);
            var moved = (x1 - x0) !== 0 || (y1 - y0) !== 0;
            var wanted = DX !== 0 || DY !== 0;
            var where = "now at (" + Math.round(x1) + ", " + Math.round(y1) + ") of ("
                + Math.round(maxX) + ", " + Math.round(maxY) + ")";
            if (wanted && !moved) {
                return L.err("failed",
                    "the page did not move: it is already at (" + Math.round(x0) + ", " + Math.round(y0)
                    + ") and the scrollable range is (" + Math.round(maxX) + ", " + Math.round(maxY) + "). "
                    + "If the content you mean lives in an inner scroller, press an element inside it first "
                    + "or use evaluate to call scrollTop on that container.");
            }
            return L.ok("scrolled by (" + Math.round(x1 - x0) + ", " + Math.round(y1 - y0) + "), " + where,
                { payload: JSON.stringify({ x: x1, y: y1, maxX: maxX, maxY: maxY }) });
            """#)
    }

    /// Cheap readiness probe used while settling.
    ///
    /// Also runs the animation-frame liveness check. WebKit gives a web view whose
    /// window was never ordered in the "hidden" page activity state, and hidden
    /// pages get no rendering updates at all — measured on macOS 26.6: zero
    /// `requestAnimationFrame` callbacks delivered, `document.getAnimations()`
    /// frozen at `currentTime` 0, and `takeSnapshot` does not pump the loop either.
    /// The probe requests a frame and reports how many earlier requests were ever
    /// served, so ``WebDriver`` can warn instead of silently handing back a canvas
    /// that never drew.
    static let readiness = #"""
        (function(){
            var docEl = document.documentElement;
            var body = document.body;
            var anims = 0;
            try {
                anims = (document.getAnimations() || [])
                    .filter(function (a) { return a.playState === "running"; }).length;
            } catch (e) {}
            var rafRequested = window.__loupeRafReq || 0;
            var rafDelivered = window.__loupeRafFired || 0;
            window.__loupeRafReq = rafRequested + 1;
            try {
                requestAnimationFrame(function () { window.__loupeRafFired = (window.__loupeRafFired || 0) + 1; });
            } catch (e) {}
            return JSON.stringify({
                ok: true,
                payload: JSON.stringify({
                    readyState: document.readyState,
                    animations: anims,
                    rafRequested: rafRequested,
                    rafDelivered: rafDelivered,
                    canvases: document.getElementsByTagName("canvas").length,
                    scrollHeight: Math.max(docEl.scrollHeight, body ? body.scrollHeight : 0),
                    scrollWidth: Math.max(docEl.scrollWidth, body ? body.scrollWidth : 0),
                    devicePixelRatio: window.devicePixelRatio,
                    innerWidth: window.innerWidth,
                    innerHeight: window.innerHeight,
                    scrollX: window.scrollX,
                    scrollY: window.scrollY,
                    title: document.title,
                    url: location.href
                })
            });
        })()
        """#

    /// Restore the scroll position after a full-page capture.
    static func scrollTo(x: Double, y: Double) -> String {
        """
        (function(){
            try { window.scrollTo({left: \(x), top: \(y), behavior: 'instant'}); }
            catch (e) { window.scrollTo(\(x), \(y)); }
            return JSON.stringify({ok:true,message:'scrolled'});
        })()
        """
    }

    /// Fallback for `evaluate` when the caller's expression produces something the
    /// JS↔ObjC bridge refuses (a Promise, a DOM node, a cyclic object).
    static let evaluateBody = #"""
        var v = await ((0, eval)(source));
        if (v === undefined) return "undefined";
        if (v === null) return "null";
        if (typeof v === "string") return v;
        try { return JSON.stringify(v); } catch (e) { return String(v); }
        """#
}
