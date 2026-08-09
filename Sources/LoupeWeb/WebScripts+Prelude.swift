import Foundation

// The helper object every injected script opens with. Split out because it is
// the one piece of JavaScript shared by every verb.

extension WebScripts {
    /// Helpers shared by every script: frame walking, hit testing, the pointer
    /// sequence, and the result envelope.
    ///
    /// Re-sent on every call instead of installed once via `WKUserScript`. It costs
    /// a few KB per IPC round trip and buys immunity from every ordering problem
    /// there is — a user script that has not run yet (document-start races,
    /// same-origin iframes created after load, a page that replaced `window`
    /// properties) would otherwise turn into a confusing "undefined is not an
    /// object" instead of an answer.
    static let prelude = #"""
        var L = {
            state: (window.__loupe = window.__loupe || { n: 0, gen: 0 }),

            cap: function (s, n) {
                if (s == null) return null;
                s = String(s).replace(/\s+/g, " ").trim();
                if (!s) return null;
                n = n || 120;
                return s.length > n ? s.slice(0, n - 1) + "…" : s;
            },

            num: function (v) {
                return Number.isFinite(v) ? Math.round(v * 100) / 100 : 0;
            },

            ok: function (message, extra) {
                var out = { ok: true, message: message };
                if (extra) for (var k in extra) out[k] = extra[k];
                return JSON.stringify(out);
            },

            err: function (code, message) {
                return JSON.stringify({ ok: false, code: code, message: message });
            },

            // Every same-origin document reachable from the top frame, each with the
            // offset from the top-level viewport to that document's own viewport.
            // Cross-origin frames are simply absent — there is no way to reach into
            // them and pretending otherwise would be the silent-no-op failure mode.
            frames: function () {
                var out = [{ doc: document, win: window, dx: 0, dy: 0 }];
                for (var i = 0; i < out.length && i < 64; i++) {
                    var f = out[i];
                    var holders = [];
                    try { holders = f.doc.querySelectorAll("iframe,frame"); } catch (e) { continue; }
                    for (var j = 0; j < holders.length; j++) {
                        var h = holders[j], cd = null, cw = null;
                        try { cd = h.contentDocument; cw = h.contentWindow; } catch (e) { cd = null; }
                        if (!cd || !cw) continue;
                        var r = h.getBoundingClientRect();
                        out.push({
                            doc: cd, win: cw,
                            dx: f.dx + r.left + (h.clientLeft || 0),
                            dy: f.dy + r.top + (h.clientTop || 0)
                        });
                    }
                }
                return out;
            },

            // querySelector that also descends into open shadow roots.
            deepQuery: function (root, sel) {
                var hit = null;
                try { hit = root.querySelector(sel); } catch (e) { hit = null; }
                if (hit) return hit;
                var all = [];
                try { all = root.querySelectorAll("*"); } catch (e) { return null; }
                for (var i = 0; i < all.length; i++) {
                    if (all[i].shadowRoot) {
                        var inner = L.deepQuery(all[i].shadowRoot, sel);
                        if (inner) return inner;
                    }
                }
                return null;
            },

            // Resolve a loupe handle to { el, doc, win, dx, dy }, searching every
            // same-origin frame and open shadow root.
            find: function (id) {
                if (!/^[A-Za-z0-9_-]+$/.test(String(id))) return null;
                var sel = '[data-loupe-id="' + id + '"]';
                var frames = L.frames();
                for (var i = 0; i < frames.length; i++) {
                    var f = frames[i];
                    var el = L.deepQuery(f.doc, sel);
                    if (el) return { el: el, doc: f.doc, win: f.win, dx: f.dx, dy: f.dy };
                }
                return null;
            },

            // Short human description, for error messages that have to name what is
            // in the way.
            desc: function (el) {
                if (!el) return "(nothing)";
                if (el.nodeType !== 1) return String(el.nodeName);
                var s = el.tagName.toLowerCase();
                if (el.id) s += "#" + el.id;
                if (el.classList && el.classList.length) {
                    s += "." + Array.prototype.slice.call(el.classList, 0, 3).join(".");
                }
                var t = L.cap(el.getAttribute("aria-label") || el.innerText || el.getAttribute("alt") || "", 40);
                return "<" + s + (t ? ' "' + t + '"' : "") + ">";
            },

            // elementFromPoint that keeps descending through open shadow roots, so a
            // web component reports the real inner target instead of its host.
            deepHit: function (doc, x, y) {
                var el = null;
                try { el = doc.elementFromPoint(x, y); } catch (e) { return null; }
                var guard = 0;
                while (el && el.shadowRoot && guard++ < 16) {
                    var inner = null;
                    try { inner = el.shadowRoot.elementFromPoint(x, y); } catch (e) { inner = null; }
                    if (!inner || inner === el) break;
                    el = inner;
                }
                return el;
            },

            // contains(), but crossing shadow boundaries via the host chain.
            isInside: function (ancestor, node) {
                var n = node, guard = 0;
                while (n && guard++ < 1024) {
                    if (n === ancestor) return true;
                    n = n.parentNode || n.host || null;
                }
                return false;
            },

            focusable: "a[href],button,input,select,textarea,summary,[tabindex],"
                + "[contenteditable=''],[contenteditable='true']",

            // The eleven events a real mouse click produces, in order, with the
            // geometry a real click would carry.
            //
            // `el.click()` fires only the last one. Everything that listens for
            // pointerdown/mousedown (Radix, Headless UI, shadcn, canvas apps, map
            // libraries, drag handles) is deaf to it, and it also bypasses hit
            // testing entirely — which is why the caller checks elementFromPoint
            // before getting here.
            pointerSeq: function (el, win, cx, cy) {
                var P = win.PointerEvent || PointerEvent;
                var M = win.MouseEvent || MouseEvent;
                var base = {
                    bubbles: true, cancelable: true, composed: true, view: win,
                    clientX: cx, clientY: cy, screenX: cx, screenY: cy, detail: 1
                };
                var pen = {};
                for (var k in base) pen[k] = base[k];
                pen.pointerId = 1; pen.pointerType = "mouse"; pen.isPrimary = true;
                pen.width = 1; pen.height = 1;

                var fired = [];
                function fire(Ctor, type, proto, opts) {
                    var init = {};
                    for (var k in proto) init[k] = proto[k];
                    if (opts) for (var k2 in opts) init[k2] = opts[k2];
                    var ev = new Ctor(type, init);
                    el.dispatchEvent(ev);
                    fired.push(type);
                    return ev;
                }

                fire(P, "pointerover", pen, { button: -1, buttons: 0 });
                fire(P, "pointerenter", pen, { button: -1, buttons: 0, bubbles: false });
                fire(M, "mouseover", base, { button: 0, buttons: 0 });
                fire(M, "mouseenter", base, { button: 0, buttons: 0, bubbles: false });
                fire(P, "pointermove", pen, { button: -1, buttons: 0 });
                fire(M, "mousemove", base, { button: 0, buttons: 0 });
                fire(P, "pointerdown", pen, { button: 0, buttons: 1, pressure: 0.5 });
                var down = fire(M, "mousedown", base, { button: 0, buttons: 1 });
                // A real mousedown moves focus to the nearest focusable ancestor
                // unless the page cancelled it. Pages that rely on focus-visible or
                // on blur handlers behave differently without this.
                if (!down.defaultPrevented) {
                    var f = null;
                    try { f = el.closest ? el.closest(L.focusable) : null; } catch (e) { f = null; }
                    if (f && typeof f.focus === "function") {
                        try { f.focus({ preventScroll: true }); } catch (e) {}
                    }
                }
                fire(P, "pointerup", pen, { button: 0, buttons: 0 });
                fire(M, "mouseup", base, { button: 0, buttons: 0 });
                var click = fire(M, "click", base, { button: 0, buttons: 0 });
                return { fired: fired, clickPrevented: click.defaultPrevented };
            },

            // Scroll into view, hit test, then dispatch. Shared by press and click.
            activate: function (el, win, doc, cx, cy, label) {
                var probe = L.deepHit(doc, cx, cy);
                if (!probe) {
                    return L.err("failed",
                        "nothing is hit-testable at (" + cx + ", " + cy + ") — the point is outside the "
                        + win.innerWidth + "×" + win.innerHeight + " viewport");
                }
                if (probe !== el && !L.isInside(el, probe)) {
                    var isAncestor = L.isInside(probe, el);
                    return L.err("blocked",
                        "(" + cx + ", " + cy + ") on " + label + " is covered by " + L.desc(probe)
                        + (isAncestor
                            ? " — an ancestor of the target, so the target has no hit area of its own "
                                + "there; press the ancestor instead"
                            : " — a real click would hit that instead, so this press was NOT delivered; "
                                + "dismiss the overlay first"));
                }
                var r = L.pointerSeq(el, win, cx, cy);
                return L.ok(
                    "pressed " + L.desc(el) + " at (" + cx + ", " + cy + ") with "
                    + r.fired.length + " events (" + r.fired.join(", ") + ")"
                    + (r.clickPrevented ? "; the page called preventDefault() on the click" : ""),
                    { payload: JSON.stringify(
                        { x: cx, y: cy, target: L.desc(el), clickPrevented: r.clickPrevented }) });
            },

            // Native value setters, bypassing whatever a framework installed on the
            // instance. React tracks the last value it wrote on the DOM node and
            // swallows an `input` event whose value it thinks it already knows, so
            // assigning `el.value = x` directly makes a controlled component snap
            // straight back to its old state.
            setNativeValue: function (el, value) {
                var proto =
                    el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype :
                    el instanceof HTMLSelectElement ? HTMLSelectElement.prototype :
                    HTMLInputElement.prototype;
                var d = Object.getOwnPropertyDescriptor(proto, "value");
                if (d && d.set) d.set.call(el, value);
                else el.value = value;
            },

            setNativeChecked: function (el, checked) {
                var d = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "checked");
                if (d && d.set) d.set.call(el, checked);
                else el.checked = checked;
            },

            notify: function (el, inputType, data) {
                var ev;
                try {
                    ev = new InputEvent("input", {
                        bubbles: true, composed: true,
                        inputType: inputType || "insertText",
                        data: data == null ? null : data
                    });
                } catch (e) {
                    ev = new Event("input", { bubbles: true });
                }
                el.dispatchEvent(ev);
                el.dispatchEvent(new Event("change", { bubbles: true }));
            },

            isVisible: function (el) {
                var st = null;
                try { st = getComputedStyle(el); } catch (e) { return false; }
                if (!st || st.display === "none" || st.visibility === "hidden") return false;
                var r = el.getBoundingClientRect();
                return r.width > 0 && r.height > 0;
            },

            isDisabled: function (el) {
                if (el.disabled) return true;
                if (el.getAttribute && el.getAttribute("aria-disabled") === "true") return true;
                try { if (el.closest && el.closest("fieldset[disabled]")) return true; } catch (e) {}
                return false;
            }
        };
        """#
}
