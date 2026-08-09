import Foundation

// The tree walker: the one script that reports rather than acts.

extension WebScripts {
    /// Walk the DOM (plus open shadow roots and same-origin iframes) into a
    /// `UINode`-shaped tree.
    static func describeTree(
        maxDepth: Int, interestingOnly: Bool, filter: String?, generation: Int
    ) -> String {
        wrap(
            #"""
            var MAX_DEPTH = \#(maxDepth);
            var INTERESTING_ONLY = \#(interestingOnly ? "true" : "false");
            var FILTER = \#(literal(filter));
            var GEN = \#(generation);
            """# + "\n" + describeTreeBody)
    }

    /// The walker itself, which takes no parameters — everything variable about
    /// a describe is declared in the four `var`s above.
    private static let describeTreeBody = #"""
        var NEEDLE = FILTER ? FILTER.toLowerCase() : null;
        L.state.gen = GEN;

        var SKIP = { script: 1, style: 1, noscript: 1, template: 1, meta: 1, link: 1, head: 1, title: 1, base: 1 };
        var ROLE_ATTR = {
            button: "button", link: "link", textbox: "textfield", searchbox: "textfield",
            checkbox: "checkbox", radio: "radio", img: "image", heading: "text",
            listbox: "list", list: "list", menu: "menu", menubar: "menu",
            menuitem: "menuitem", menuitemcheckbox: "menuitem", menuitemradio: "menuitem",
            tab: "button", tablist: "list", switch: "checkbox", combobox: "list",
            option: "cell", row: "cell", cell: "cell", gridcell: "cell",
            dialog: "window", alertdialog: "window", navigation: "group", main: "group"
        };
        var TEXTY = { h1: 1, h2: 1, h3: 1, h4: 1, h5: 1, h6: 1, p: 1, span: 1, label: 1, strong: 1,
            em: 1, b: 1, i: 1, small: 1, code: 1, pre: 1, blockquote: 1, figcaption: 1,
            legend: 1, dt: 1, dd: 1, caption: 1, time: 1, output: 1 };
        var GROUPY = { body: 1, html: 1, div: 1, section: 1, nav: 1, header: 1, footer: 1, main: 1, aside: 1,
            article: 1, form: 1, fieldset: 1, table: 1, tbody: 1, thead: 1, tr: 1, dl: 1,
            details: 1, figure: 1, picture: 1 };

        var docW = Math.max(
            document.documentElement ? document.documentElement.scrollWidth : 0,
            document.body ? document.body.scrollWidth : 0, window.innerWidth);
        var docH = Math.max(
            document.documentElement ? document.documentElement.scrollHeight : 0,
            document.body ? document.body.scrollHeight : 0, window.innerHeight);

        function handleFor(el) {
            var id = null;
            try { id = el.getAttribute("data-loupe-id"); } catch (e) {}
            if (id && id.indexOf("g" + GEN + "n") === 0) return id;
            id = "g" + GEN + "n" + (++L.state.n);
            try { el.setAttribute("data-loupe-id", id); } catch (e) {}
            return id;
        }

        function inputRole(el) {
            var t = (el.getAttribute("type") || "text").toLowerCase();
            if (t === "checkbox") return "checkbox";
            if (t === "radio") return "radio";
            if (t === "button" || t === "submit" || t === "reset" || t === "image") return "button";
            if (t === "range") return "slider";
            if (t === "color" || t === "file") return "button";
            return "textfield";
        }

        function roleOf(el, tag) {
            var explicit = (el.getAttribute("role") || "").toLowerCase();
            if (explicit && ROLE_ATTR[explicit]) return ROLE_ATTR[explicit];
            switch (tag) {
                case "button": return "button";
                case "a": return el.hasAttribute("href") ? "link" : "text";
                case "area": return el.hasAttribute("href") ? "link" : "other";
                case "summary": return "button";
                case "input": return inputRole(el);
                case "textarea": return "textfield";
                case "select": return "list";
                case "option": return "cell";
                case "img": case "svg": case "canvas": case "video": case "figure": return "image";
                case "ul": case "ol": case "menu": return "list";
                case "li": case "td": case "th": return "cell";
                case "iframe": case "frame": return "group";
                case "dialog": return "window";
                case "progress": case "meter": return "other";
            }
            if (TEXTY[tag]) return "text";
            if (GROUPY[tag]) return "group";
            return "other";
        }

        function ownText(el) {
            var s = "";
            for (var i = 0; i < el.childNodes.length && i < 64; i++) {
                var n = el.childNodes[i];
                if (n.nodeType === 3) s += n.nodeValue;
            }
            return s;
        }

        function labelOf(el, tag, role) {
            var aria = el.getAttribute("aria-label");
            if (L.cap(aria)) return L.cap(aria);
            var by = el.getAttribute("aria-labelledby");
            if (by) {
                var parts = by.split(/\s+/), txt = "";
                for (var i = 0; i < parts.length; i++) {
                    var ref = null;
                    try { ref = (el.ownerDocument || document).getElementById(parts[i]); } catch (e) {}
                    if (ref) txt += " " + (ref.innerText || ref.textContent || "");
                }
                if (L.cap(txt)) return L.cap(txt);
            }
            var alt = el.getAttribute("alt");
            if (L.cap(alt)) return L.cap(alt);
            var ph = el.getAttribute("placeholder");
            if (L.cap(ph)) return L.cap(ph);
            if (tag === "input") {
                var t = (el.getAttribute("type") || "text").toLowerCase();
                if (t === "button" || t === "submit" || t === "reset") {
                    if (L.cap(el.value)) return L.cap(el.value);
                }
                // A wrapping or `for=`-associated <label> is what a human reads.
                var lbls = el.labels;
                if (lbls && lbls.length && L.cap(lbls[0].innerText)) return L.cap(lbls[0].innerText);
            }
            // Interactive elements own their whole text ("<button><span>Save</span>"),
            // containers only own their direct text — otherwise every wrapper would
            // be labelled with the entire page.
            if (role === "button" || role === "link" || role === "menuitem" || tag === "label"
                || tag === "summary" || tag === "option") {
                var it = L.cap(el.innerText || el.textContent);
                if (it) return it;
            }
            if (role === "text") {
                // A paragraph that *contains* a link must not take the link's text as
                // its own label: it would tie with the link when a caller resolves by
                // label and win on document order, and pressing the paragraph's centre
                // is not pressing the link. Measured on example.com, where
                // <p><a>Learn more</a></p> otherwise swallowed the only link on the page.
                var interactive = null;
                try {
                    interactive = el.querySelector(
                        "a[href],button,input,select,textarea,summary,[role='button'],[role='link'],[onclick]");
                } catch (e) { interactive = null; }
                if (!interactive) {
                    var own2 = L.cap(el.innerText || el.textContent);
                    if (own2) return own2;
                }
            }
            var own = L.cap(ownText(el));
            if (own) return own;
            var title = el.getAttribute("title");
            if (L.cap(title)) return L.cap(title);
            return null;
        }

        function valueOf(el, tag) {
            if (tag === "input") {
                var t = (el.getAttribute("type") || "text").toLowerCase();
                if (t === "checkbox" || t === "radio") return el.checked ? "checked" : "unchecked";
                if (t === "password") return el.value ? "•".repeat(Math.min(el.value.length, 12)) : null;
                if (t === "file") return el.files && el.files.length ? el.files[0].name : null;
                return L.cap(el.value, 200);
            }
            if (tag === "textarea") return L.cap(el.value, 200);
            if (tag === "select") {
                var o = el.options[el.selectedIndex];
                return L.cap(o ? (o.value || o.text) : el.value, 200);
            }
            if (tag === "progress" || tag === "meter") return String(el.value);
            if (el.isContentEditable) return L.cap(el.innerText, 200);
            var ac = el.getAttribute("aria-checked") || el.getAttribute("aria-selected")
                || el.getAttribute("aria-valuenow") || el.getAttribute("aria-expanded");
            return ac ? String(ac) : null;
        }

        function actionsOf(el, tag, role) {
            var out = [];
            var clickable =
                role === "button" || role === "link" || role === "checkbox" || role === "radio"
                || role === "menuitem" || role === "slider"
                || tag === "label" || tag === "option" || tag === "select"
                || el.hasAttribute("onclick") || el.hasAttribute("ng-click")
                || (el.getAttribute("tabindex") !== null && el.getAttribute("tabindex") !== "-1");
            if (!clickable) {
                // A pointer cursor is the web's own "this is clickable" signal, and
                // catches div-based buttons that carry no semantics at all.
                try { clickable = getComputedStyle(el).cursor === "pointer"; } catch (e) {}
            }
            if (clickable && !L.isDisabled(el)) out.push("press");
            if (!L.isDisabled(el)) {
                if (role === "textfield" || tag === "select" || el.isContentEditable) out.push("setValue");
                if (role === "checkbox" || role === "radio") out.push("setValue");
            }
            return out;
        }

        function matchesNeedle(n) {
            if (!NEEDLE) return false;
            var hay = [n.label, n.value, n.identifier, n.id];
            for (var i = 0; i < hay.length; i++) {
                if (hay[i] && String(hay[i]).toLowerCase().indexOf(NEEDLE) >= 0) return true;
            }
            return false;
        }

        function interesting(n) {
            return !!(n.label || n.value || n.identifier || (n.actions && n.actions.length));
        }

        function childrenOf(el, tag) {
            var kids = [];
            if (el.shadowRoot) {
                for (var i = 0; i < el.shadowRoot.children.length; i++) kids.push(el.shadowRoot.children[i]);
            }
            for (var j = 0; j < el.children.length; j++) kids.push(el.children[j]);
            return kids;
        }

        // Returns an array so an invisible wrapper can hoist its children into
        // the parent instead of vanishing with them.
        function walk(el, depth, dx, dy, matchedAncestor) {
            if (!el || el.nodeType !== 1) return [];
            var tag = el.tagName.toLowerCase();
            if (SKIP[tag]) return [];

            var st = null;
            try { st = getComputedStyle(el); } catch (e) { st = null; }
            // display:none prunes the subtree: computed style does not inherit
            // `display`, so a child of a hidden parent still reports "block" and
            // would otherwise be reported as visible.
            if (st && st.display === "none") return [];

            var r = el.getBoundingClientRect();
            var x = r.left + dx, y = r.top + dy;
            var zero = r.width <= 0 || r.height <= 0;
            // Parked off the document (the classic `left:-9999px` hiding trick).
            // Below-the-fold content is deliberately NOT skipped — it is reachable
            // by scrolling and an agent needs to know it exists.
            if (!zero && (x + r.width < -1 || y + r.height < -1 || x > docW + 1 || y > docH + 1)) return [];

            var hiddenSelf = zero || (st && st.visibility === "hidden");
            var role = roleOf(el, tag);
            var node = null, selfMatches = false;

            if (!hiddenSelf) {
                node = {
                    id: handleFor(el),
                    role: role,
                    // `input:password`, not bare `input`: the type is the only
                    // thing separating a password box from a search box once
                    // both have normalized to "textfield", and a caller asking
                    // for one specifically has nowhere else to look.
                    rawRole: (el.getAttribute("role") || "").toLowerCase()
                        || (tag === "input"
                            ? tag + ":" + (el.getAttribute("type") || "text").toLowerCase()
                            : tag),
                    label: labelOf(el, tag, role),
                    value: valueOf(el, tag),
                    identifier: el.id || null,
                    x: L.num(x), y: L.num(y), w: L.num(r.width), h: L.num(r.height),
                    enabled: !L.isDisabled(el),
                    focused: el === (el.ownerDocument || document).activeElement,
                    actions: actionsOf(el, tag, role),
                    children: []
                };
                selfMatches = matchesNeedle(node);
            }

            var kids = [];
            if (depth < MAX_DEPTH) {
                var cdx = dx, cdy = dy, list = childrenOf(el, tag);
                if (tag === "iframe" || tag === "frame") {
                    var cd = null;
                    try { cd = el.contentDocument; } catch (e) { cd = null; }
                    if (cd && cd.body) {
                        list = [cd.body];
                        cdx = x + (el.clientLeft || 0);
                        cdy = y + (el.clientTop || 0);
                    } else if (node) {
                        // WebKit gives every file:// document its own opaque origin, so a
                        // local page cannot reach into its own local iframe either — worth
                        // saying, because the fix is different from a real cross-origin frame.
                        node.label = (node.label || "iframe")
                            + (location.protocol === "file:"
                                ? " (a file:// document is its own origin in WebKit, so this frame cannot be "
                                    + "inspected or driven — serve the page over http://localhost instead)"
                                : " (cross-origin — contents cannot be inspected or driven)");
                        // The label only just came into existence, so the filter has to be
                        // re-tested against it.
                        selfMatches = matchesNeedle(node);
                    }
                }
                for (var i = 0; i < list.length; i++) {
                    var got = walk(list[i], depth + 1, cdx, cdy, matchedAncestor || selfMatches);
                    for (var k = 0; k < got.length; k++) kids.push(got[k]);
                }
            }

            if (!node) return kids;
            node.children = kids;

            if (NEEDLE && !matchedAncestor && !selfMatches && kids.length === 0) return [];
            if (INTERESTING_ONLY && !interesting(node) && !selfMatches) return kids;
            return [node];
        }

        var body = document.body || document.documentElement;
        var roots = body ? walk(body, 1, 0, 0, false) : [];
        var page = {
            id: "g" + GEN + "n0",
            role: "window",
            rawRole: "#document",
            label: L.cap(document.title) || location.hostname,
            value: L.cap(location.href, 300),
            identifier: null,
            x: 0, y: 0, w: L.num(window.innerWidth), h: L.num(window.innerHeight),
            enabled: true,
            focused: true,
            actions: [],
            children: roots
        };
        return L.ok("described " + document.title, { nodes: [page] });
        """#
}
