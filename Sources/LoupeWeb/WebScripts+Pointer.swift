import Foundation

// Pressing things: by handle, and by raw viewport coordinate.

extension WebScripts {
    /// Full synthetic click on a described element.
    static func press(handle: String, generation: Int) -> String {
        wrap(
            #"""
            var ID = \#(literal(handle));
            var hit = L.find(ID);
            if (!hit) {
                return L.err("nodeNotFound",
                    "no element carries handle '" + ID + "' any more. Handles are stamped onto the DOM by "
                    + "describe and are wiped by navigation or a re-render — describe again and use a fresh one.");
            }
            var el = hit.el;
            try { el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" }); }
            catch (e) { el.scrollIntoView(true); }
            var r = el.getBoundingClientRect();
            if (r.width <= 0 || r.height <= 0) {
                return L.err("failed", L.desc(el) + " has a zero-sized box, so there is no point to press.");
            }
            var vw = hit.win.innerWidth, vh = hit.win.innerHeight;
            var cx = Math.round(r.left + r.width / 2);
            var cy = Math.round(r.top + r.height / 2);
            if (cx < 0 || cy < 0 || cx > vw || cy > vh) {
                return L.err("failed",
                    "after scrollIntoView the centre of " + L.desc(el) + " is still at (" + cx + ", " + cy
                    + "), outside the " + vw + "×" + vh + " viewport — it is probably inside a "
                    + "clipped or transformed container.");
            }
            cx = Math.min(Math.max(cx, 1), vw - 1);
            cy = Math.min(Math.max(cy, 1), vh - 1);
            return L.activate(el, hit.win, hit.doc, cx, cy, L.desc(el));
            """#)
    }

    /// Full synthetic click at raw viewport coordinates.
    static func click(x: Double, y: Double) -> String {
        wrap(
            #"""
            var X = \#(x), Y = \#(y);
            // Descend into same-origin iframes so a coordinate lands where the pixel is.
            var doc = document, win = window, cx = Math.round(X), cy = Math.round(Y), guard = 0;
            while (guard++ < 8) {
                var el = L.deepHit(doc, cx, cy);
                if (!el) break;
                var tag = el.tagName ? el.tagName.toLowerCase() : "";
                if (tag !== "iframe" && tag !== "frame") break;
                var cd = null, cw = null;
                try { cd = el.contentDocument; cw = el.contentWindow; } catch (e) { cd = null; }
                if (!cd || !cw) break;
                var fr = el.getBoundingClientRect();
                cx = cx - fr.left - (el.clientLeft || 0);
                cy = cy - fr.top - (el.clientTop || 0);
                doc = cd; win = cw;
            }
            var target = L.deepHit(doc, cx, cy);
            if (!target) {
                return L.err("failed",
                    "nothing at (" + X + ", " + Y + ") — the viewport is "
                    + window.innerWidth + "×" + window.innerHeight + " CSS px and coordinates are "
                    + "viewport-relative, matching the frames reported by describe.");
            }
            return L.activate(target, win, doc, cx, cy, "(" + X + ", " + Y + ")");
            """#)
    }
}
