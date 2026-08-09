import Foundation

// Putting text and keystrokes into a page.

extension WebScripts {
    /// Set a form control's value the way a framework-aware human would.
    static func setValue(handle: String, value: String) -> String {
        wrap(
            #"""
            var ID = \#(literal(handle));
            var V = \#(literal(value));
            """# + "\n" + setValueBody)
    }

    private static let setValueBody = #"""
        var hit = L.find(ID);
        if (!hit) {
            return L.err("nodeNotFound",
                "no element carries handle '" + ID + "' any more — describe again for a fresh one.");
        }
        var el = hit.el;
        var tag = el.tagName.toLowerCase();
        // Empty for anything that is not an <input>, so the checks below can just
        // compare a type without repeating the tag test.
        var inputType = tag === "input" ? (el.type || "").toLowerCase() : "";
        if (L.isDisabled(el)) {
            return L.err("failed", L.desc(el) + " is disabled, so its value cannot be set.");
        }
        try { el.focus({ preventScroll: true }); } catch (e) {}

        if (inputType === "file") {
            return L.err("unsupported",
                "file inputs cannot be filled from JavaScript for security reasons. Drive the upload "
                + "from the app side, or use a mac: target and the real open panel.");
        }

        if (inputType === "checkbox" || inputType === "radio") {
            var want = /^(1|true|on|yes|check|checked)$/i.test(V) ? true
                : /^(0|false|off|no|uncheck|unchecked)$/i.test(V) ? false
                : /^toggle$/i.test(V) ? !el.checked : null;
            if (want === null) {
                return L.err("failed",
                    "'" + V + "' is not a checkbox value — use true/false/toggle.");
            }
            L.setNativeChecked(el, want);
            L.notify(el, "insertText", null);
            if (el.checked !== want) {
                return L.err("failed",
                    L.desc(el) + " refused the change and is still "
                    + (el.checked ? "checked" : "unchecked") + ".");
            }
            return L.ok("set " + L.desc(el) + " to " + (want ? "checked" : "unchecked")
                + " and fired input + change", { payload: want ? "checked" : "unchecked" });
        }

        if (tag === "select") {
            var opt = null, i;
            for (i = 0; i < el.options.length; i++) if (el.options[i].value === V) { opt = el.options[i]; break; }
            if (!opt) for (i = 0; i < el.options.length; i++) {
                if ((el.options[i].text || "").trim() === V.trim()) { opt = el.options[i]; break; }
            }
            if (!opt) {
                var avail = [];
                for (i = 0; i < el.options.length && i < 25; i++) {
                    avail.push(
                        JSON.stringify(el.options[i].value)
                        + " (\"" + (el.options[i].text || "").trim() + "\")");
                }
                return L.err("failed",
                    "no option matching '" + V + "' in " + L.desc(el) + ". Available: " + avail.join(", "));
            }
            L.setNativeValue(el, opt.value);
            L.notify(el, "insertText", opt.value);
            return L.ok("selected \"" + (opt.text || "").trim() + "\" in " + L.desc(el)
                + " and fired input + change", { payload: opt.value });
        }

        if (el.isContentEditable) {
            el.textContent = V;
            L.notify(el, "insertText", V);
            return L.ok("replaced the contents of " + L.desc(el) + " and fired input + change",
                { payload: V });
        }

        if (tag !== "input" && tag !== "textarea") {
            return L.err("unsupported",
                L.desc(el) + " is not a form control or contenteditable — there is no value to set. "
                + "Use press for buttons and links.");
        }

        L.setNativeValue(el, V);
        L.notify(el, "insertText", V);
        if (el.value !== V) {
            return L.err("failed",
                L.desc(el) + " did not keep the value: asked for " + JSON.stringify(V)
                + ", it now holds " + JSON.stringify(el.value)
                + " (maxlength, an input mask, or a type that rejects this text).");
        }
        return L.ok("set " + L.desc(el) + " to " + JSON.stringify(L.cap(V, 60))
            + " via the native value setter and fired input + change", { payload: V });
        """#

    /// Type into whatever currently has focus, one character at a time.
    static func type(text: String) -> String {
        wrap(#"var TEXT = \#(literal(text));"# + "\n" + typeBody)
    }

    private static let typeBody = #"""
        // Focus can live inside a same-origin iframe; document.activeElement of the
        // top frame would only report the <iframe> element itself.
        var frames = L.frames(), el = null, win = window, doc = document;
        for (var i = 0; i < frames.length; i++) {
            var a = frames[i].doc.activeElement;
            if (a && a.tagName && a.tagName.toLowerCase() !== "iframe" && a.tagName.toLowerCase() !== "frame"
                && a !== frames[i].doc.body && a !== frames[i].doc.documentElement) {
                el = a; win = frames[i].win; doc = frames[i].doc;
                break;
            }
        }
        if (!el) {
            return L.err("failed",
                "nothing has keyboard focus, so there is nowhere to type. Press the field first "
                + "(press focuses the way a real mousedown does), or use setValue.");
        }
        var tag = el.tagName.toLowerCase();
        var editable = el.isContentEditable || tag === "input" || tag === "textarea";
        if (!editable) {
            return L.err("failed",
                "focus is on " + L.desc(el) + ", which does not accept text. Press a text field first.");
        }

        function keyEvents(ch) {
            var init = { key: ch, code: "", bubbles: true, cancelable: true, composed: true, view: win };
            var kd = new KeyboardEvent("keydown", init);
            el.dispatchEvent(kd);
            el.dispatchEvent(new KeyboardEvent("keypress", init));
            return kd.defaultPrevented;
        }

        var typed = 0, prevented = 0;
        for (var c = 0; c < TEXT.length; c++) {
            var ch = TEXT[c];
            var blocked = keyEvents(ch);
            if (blocked) {
                prevented++;
            } else if (el.isContentEditable) {
                var inserted = false;
                try { inserted = doc.execCommand("insertText", false, ch); } catch (e) { inserted = false; }
                if (!inserted) el.textContent += ch;
                typed++;
            } else {
                // Insert at the caret rather than appending, which is what typing does.
                var start = null, end = null;
                try { start = el.selectionStart; end = el.selectionEnd; } catch (e) { start = null; }
                var v = el.value;
                if (start === null || start === undefined) {
                    L.setNativeValue(el, v + ch);
                } else {
                    L.setNativeValue(el, v.slice(0, start) + ch + v.slice(end));
                    try { el.selectionStart = el.selectionEnd = start + ch.length; } catch (e) {}
                }
                typed++;
                var ev;
                try {
                    ev = new InputEvent("input", { bubbles: true, composed: true, inputType: "insertText", data: ch });
                } catch (e) {
                    ev = new Event("input", { bubbles: true });
                }
                el.dispatchEvent(ev);
            }
            el.dispatchEvent(new KeyboardEvent("keyup", {
                key: ch, bubbles: true, cancelable: true, composed: true, view: win
            }));
        }

        return L.ok(
            "typed " + typed + " of " + TEXT.length + " character(s) into " + L.desc(el)
            + (prevented ? " (" + prevented + " suppressed by the page's keydown handler)" : "")
            + ". change fires on blur, as in a real browser — send key 'tab' or press elsewhere if the page needs it.",
            { payload: el.isContentEditable ? L.cap(el.innerText, 200) : L.cap(el.value, 200) });
        """#

    /// Named key, with the few default actions a synthetic event cannot produce
    /// on its own emulated explicitly.
    static func key(_ combo: String) -> String {
        wrap(#"var COMBO = \#(literal(combo));"# + "\n" + keyBody)
    }

    private static let keyBody = #"""
        var parts = COMBO.split("+").map(function (s) { return s.trim().toLowerCase(); }).filter(Boolean);
        var mods = { metaKey: false, ctrlKey: false, altKey: false, shiftKey: false };
        var name = null;
        for (var i = 0; i < parts.length; i++) {
            var p = parts[i];
            if (p === "cmd" || p === "command" || p === "meta") mods.metaKey = true;
            else if (p === "ctrl" || p === "control") mods.ctrlKey = true;
            else if (p === "alt" || p === "option" || p === "opt") mods.altKey = true;
            else if (p === "shift") mods.shiftKey = true;
            else name = p;
        }
        if (!name) return L.err("failed", "'" + COMBO + "' names no key, only modifiers.");

        var TABLE = {
            enter: ["Enter", "Enter", 13], "return": ["Enter", "Enter", 13],
            tab: ["Tab", "Tab", 9],
            escape: ["Escape", "Escape", 27], esc: ["Escape", "Escape", 27],
            space: [" ", "Space", 32],
            // macOS naming: the key labelled Delete is Backspace. `forwarddelete`
            // is the fn-Delete / PC Delete key.
            "delete": ["Backspace", "Backspace", 8], backspace: ["Backspace", "Backspace", 8],
            forwarddelete: ["Delete", "Delete", 46],
            up: ["ArrowUp", "ArrowUp", 38], down: ["ArrowDown", "ArrowDown", 40],
            left: ["ArrowLeft", "ArrowLeft", 37], right: ["ArrowRight", "ArrowRight", 39],
            home: ["Home", "Home", 36], end: ["End", "End", 35],
            pageup: ["PageUp", "PageUp", 33], pagedown: ["PageDown", "PageDown", 34]
        };
        var spec = TABLE[name];
        if (!spec) {
            if (name.length === 1) {
                spec = [
                    mods.shiftKey ? name.toUpperCase() : name,
                    "Key" + name.toUpperCase(),
                    name.toUpperCase().charCodeAt(0)
                ];
            } else if (/^f([1-9]|1[0-9]|2[0-4])$/.test(name)) {
                spec = [name.toUpperCase(), name.toUpperCase(), 111 + parseInt(name.slice(1), 10)];
            } else {
                return L.err("failed",
                    "unknown key '" + name + "'. Known: enter, tab, escape, space, delete, forwarddelete, "
                    + "up, down, left, right, home, end, pageup, pagedown, f1–f24, or a single character.");
            }
        }

        var frames = L.frames(), el = document.activeElement, win = window, doc = document;
        for (var f = 0; f < frames.length; f++) {
            var a = frames[f].doc.activeElement;
            if (a && a.tagName && a.tagName.toLowerCase() !== "iframe" && a.tagName.toLowerCase() !== "frame") {
                el = a; win = frames[f].win; doc = frames[f].doc;
                break;
            }
        }
        el = el || document.body;

        var init = {
            key: spec[0], code: spec[1], keyCode: spec[2], which: spec[2],
            bubbles: true, cancelable: true, composed: true, view: win,
            metaKey: mods.metaKey, ctrlKey: mods.ctrlKey, altKey: mods.altKey, shiftKey: mods.shiftKey
        };
        var kd = new KeyboardEvent("keydown", init);
        el.dispatchEvent(kd);
        var prevented = kd.defaultPrevented;
        if (spec[0].length === 1 && !mods.metaKey && !mods.ctrlKey) {
            el.dispatchEvent(new KeyboardEvent("keypress", init));
        }

        // Synthetic key events are untrusted: WebKit runs no default action for
        // them. Everything below re-creates, explicitly and reportably, the small
        // set of defaults an agent actually depends on. Anything not listed here
        // reaches the page's handlers only.
        var did = null;
        var tag = el.tagName ? el.tagName.toLowerCase() : "";
        var isText = (tag === "input" && !/^(checkbox|radio|button|submit|reset|file|image)$/i.test(el.type || "text"))
            || tag === "textarea";
        var plain = !mods.metaKey && !mods.ctrlKey && !mods.altKey;
        // What a browser activates when Enter or Space arrives on the focused element.
        var ACTIVATABLE = "button,summary,a[href],[role='button'],input[type='submit'],"
            + "input[type='button'],input[type='checkbox'],input[type='radio']";

        function caret(el) {
            try { return [el.selectionStart, el.selectionEnd]; } catch (e) { return null; }
        }

        if (!prevented && plain && spec[0] === "Tab") {
            var all = [];
            try { all = Array.prototype.slice.call(doc.querySelectorAll(L.focusable)); } catch (e) {}
            all = all.filter(function (n) {
                return n.getAttribute("tabindex") !== "-1" && !L.isDisabled(n) && L.isVisible(n);
            });
            if (all.length) {
                var idx = all.indexOf(el);
                var next = all[(idx + (mods.shiftKey ? -1 : 1) + all.length * 2) % all.length];
                if (next && next.focus) {
                    next.focus({ preventScroll: true });
                    did = "moved focus to " + L.desc(next);
                }
            }
        } else if (!prevented && plain && (spec[0] === "Enter" || spec[0] === " ")) {
            var act = null;
            try { act = el.closest(ACTIVATABLE); } catch (e) {}
            if (act && !(spec[0] === " " && act.tagName.toLowerCase() === "a")) {
                var rr = act.getBoundingClientRect();
                L.pointerSeq(act, win, Math.round(rr.left + rr.width / 2), Math.round(rr.top + rr.height / 2));
                did = "activated " + L.desc(act) + " the way a browser activates the focused control";
            } else if (spec[0] === "Enter" && isText && el.form) {
                // Implicit submission: exactly what a browser does for Enter in a
                // single-line field.
                var submit = null;
                try {
                    submit = el.form.querySelector(
                        "button:not([type=button]):not([type=reset]),input[type=submit]");
                } catch (e) {}
                if (submit) {
                    var sr = submit.getBoundingClientRect();
                    L.pointerSeq(submit, win, Math.round(sr.left + sr.width / 2), Math.round(sr.top + sr.height / 2));
                    did = "submitted the form by activating " + L.desc(submit);
                } else if (el.form.requestSubmit) {
                    el.form.requestSubmit();
                    did = "submitted <form" + (el.form.id ? "#" + el.form.id : "") + "> (no submit button to click)";
                }
            }
        } else if (!prevented && plain && isText && (spec[0] === "Backspace" || spec[0] === "Delete")) {
            var c = caret(el), v = el.value;
            if (c && c[0] !== null) {
                var s = c[0], e2 = c[1];
                if (s !== e2) {
                    L.setNativeValue(el, v.slice(0, s) + v.slice(e2));
                } else if (spec[0] === "Backspace" && s > 0) {
                    L.setNativeValue(el, v.slice(0, s - 1) + v.slice(s));
                    s = s - 1;
                } else if (spec[0] === "Delete" && s < v.length) {
                    L.setNativeValue(el, v.slice(0, s) + v.slice(s + 1));
                }
                try { el.selectionStart = el.selectionEnd = s; } catch (e3) {}
                el.dispatchEvent(new Event("input", { bubbles: true }));
                did = "deleted a character";
            }
        } else if (!prevented && plain && isText && /^(ArrowLeft|ArrowRight|Home|End)$/.test(spec[0])) {
            var c2 = caret(el);
            if (c2 && c2[0] !== null) {
                var pos = spec[0] === "ArrowLeft" ? Math.max(0, c2[0] - 1)
                    : spec[0] === "ArrowRight" ? Math.min(el.value.length, c2[1] + 1)
                    : spec[0] === "Home" ? 0 : el.value.length;
                try { el.selectionStart = el.selectionEnd = pos; did = "moved the caret to " + pos; } catch (e4) {}
            }
        }

        el.dispatchEvent(new KeyboardEvent("keyup", init));

        var msg = "sent " + COMBO + " (keydown"
            + (prevented ? ", defaultPrevented by the page" : "")
            + " + keyup) to " + L.desc(el);
        if (did) msg += "; " + did;
        else if (!prevented) msg += "; the page's handlers ran, but WebKit performs no default action for a "
            + "synthetic key event — nothing else happened";
        return L.ok(msg, { payload: did || "" });
        """#
}
