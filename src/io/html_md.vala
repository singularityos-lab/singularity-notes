namespace Singularity.Apps.Notes {

    public class HtmlImage : Object {
        public string src { get; construct; }
        public Block block { get; construct; }

        public HtmlImage(string src, Block block) {
            Object(src: src, block: block);
        }
    }

    public class HtmlConverter : Object {
        public string base_url { get; set; default = ""; }
        public Gee.ArrayList<Block> blocks = new Gee.ArrayList<Block>();
        public Gee.ArrayList<HtmlImage> images = new Gee.ArrayList<HtmlImage>();
        public string title = "";
        public int heading_shift { get; set; default = 1; }

        private Block? current = null;
        private int list_depth = 0;
        private Gee.ArrayList<BlockKind> list_kinds = new Gee.ArrayList<BlockKind>();
        private bool bold;
        private bool italic;
        private bool underline;
        private bool strike;
        private bool code;
        private string highlight = "";
        private string color = "";
        private string href = "";
        private bool in_pre = false;

        private const string[] SKIP = { "script", "style", "noscript", "nav", "footer", "aside", "form", "iframe", "svg", "button", "input", "select", "textarea", "head", "template", "object", "embed" };
        private const string[] BLOCKS = { "p", "div", "section", "article", "main", "header", "figure", "figcaption", "address", "dl", "dt", "dd", "center", "details", "summary", "en-note", "body" };

        public static string to_markdown(string html, string base_url = "", bool main_only = false) {
            var c = new HtmlConverter();
            c.base_url = base_url;
            c.convert(html, main_only);
            return RichText.render(c.blocks);
        }

        public void convert(string html, bool main_only) {
            blocks.clear();
            images.clear();
            string text = html;
            if (text.strip() == "") return;
            Html.Doc* doc = Html.Doc.read_memory(text.to_utf8(), text.length, base_url != "" ? base_url : "about:blank", "UTF-8",
                Html.ParserOption.RECOVER | Html.ParserOption.NOERROR | Html.ParserOption.NOWARNING | Html.ParserOption.NONET);
            if (doc == null) return;
            Xml.Node* root = doc->get_root_element();
            if (root != null) {
                Xml.Node* t = find(root, "title");
                if (t != null) title = collapse(t->get_content()).strip();
                Xml.Node* start = root;
                if (main_only) {
                    Xml.Node* article = find(root, "article");
                    Xml.Node* main_el = find(root, "main");
                    if (article != null) start = article;
                    else if (main_el != null) start = main_el;
                    else {
                        Xml.Node* body = find(root, "body");
                        if (body != null) start = body;
                    }
                }
                walk(start);
                flush();
            }
            delete doc;
            while (blocks.size > 0 && blocks[blocks.size - 1].plain_text().strip() == "" && !blocks[blocks.size - 1].kind.is_object()) blocks.remove_at(blocks.size - 1);
            var cleaned = new Gee.ArrayList<Block>();
            bool prev_empty = false;
            foreach (var b in blocks) {
                bool empty = !b.kind.is_object() && b.plain_text().strip() == "" && b.kind != BlockKind.CODE;
                if (empty && (prev_empty || cleaned.size == 0)) continue;
                cleaned.add(b);
                prev_empty = empty;
            }
            blocks = cleaned;
        }

        private static Xml.Node* find(Xml.Node* node, string name) {
            for (Xml.Node* n = node; n != null; n = n->next) {
                if (n->type == Xml.ElementType.ELEMENT_NODE) {
                    if (n->name.down() == name) return n;
                    Xml.Node* inner = find(n->children, name);
                    if (inner != null) return inner;
                }
            }
            return null;
        }

        private static string collapse(string s) {
            var sb = new StringBuilder();
            bool space = false;
            unichar c;
            int i = 0;
            while (s.get_next_char(ref i, out c)) {
                if (c == ' ' || c == '\n' || c == '\t' || c == '\r' || c == 0xa0) {
                    if (!space) sb.append_c(' ');
                    space = true;
                } else {
                    sb.append_unichar(c);
                    space = false;
                }
            }
            return sb.str;
        }

        private void flush() {
            if (current == null) return;
            if (current.kind != BlockKind.PARAGRAPH || current.plain_text().strip() != "" || current.tags.length > 0) {
                if (current.spans.size > 0) {
                    var first = current.spans[0];
                    first.text = first.text.chug();
                    var last = current.spans[current.spans.size - 1];
                    last.text = last.text.chomp();
                }
                blocks.add(current);
            } else if (blocks.size > 0) {
                blocks.add(new Block(BlockKind.PARAGRAPH));
            }
            current = null;
        }

        private void ensure_block() {
            if (current != null) return;
            if (list_depth > 0) {
                current = new Block(list_kinds[list_kinds.size - 1]);
                current.indent = list_depth - 1;
            } else {
                current = new Block(BlockKind.PARAGRAPH);
            }
        }

        private void add_text(string raw) {
            string t = in_pre ? raw : collapse(raw);
            if (t == "") return;
            if (in_pre) {
                string[] lines = t.split("\n");
                for (int i = 0; i < lines.length; i++) {
                    if (i > 0) flush();
                    if (current == null) {
                        current = new Block(BlockKind.CODE);
                    }
                    current.raw += lines[i];
                }
                return;
            }
            if (current == null && t.strip() == "") return;
            ensure_block();
            if (current.spans.size == 0) t = take_check_glyph(t);
            if (t == "") return;
            var s = new Span(t, bold, italic, href);
            s.underline = underline;
            s.strike = strike;
            s.code = code;
            s.highlight = highlight;
            s.color = color;
            current.add(s);
        }

        private string absolute(string url) {
            if (url.has_prefix("http://") || url.has_prefix("https://") || url.has_prefix("data:") || url.has_prefix("mailto:")) return url;
            if (base_url == "") return url;
            try {
                return Uri.resolve_relative(base_url, url, UriFlags.NONE);
            } catch (UriError e) {
                return url;
            }
        }

        private string take_check_glyph(string t) {
            string s = t.chug();
            bool on;
            if (s.has_prefix(NoteClip.CHECKED) || s.has_prefix("☒")) on = true;
            else if (s.has_prefix(NoteClip.UNCHECKED)) on = false;
            else return t;
            if (current.kind != BlockKind.CHECK) {
                current.kind = BlockKind.CHECK;
                current.checked = on;
            }
            return s.substring(NoteClip.CHECKED.length).chug();
        }

        private void checkbox(Xml.Node* n) {
            if ((n->get_prop("type") ?? "").down() != "checkbox") return;
            ensure_block();
            if (current.plain_text().strip() != "") return;
            current.kind = BlockKind.CHECK;
            current.checked = n->get_prop("checked") != null;
        }

        private static string? style_prop(string? style, string name) {
            if (style == null) return null;
            foreach (string decl in style.split(";")) {
                int colon = decl.index_of(":");
                if (colon < 0) continue;
                if (decl.substring(0, colon).strip().down() == name) return decl.substring(colon + 1).strip().down();
            }
            return null;
        }

        private static string? hex_of(string? v) {
            if (v == null) return null;
            string s = v.strip();
            if (s.has_prefix("#") && (s.length == 7 || s.length == 4)) return s;
            if (s.has_prefix("rgb")) {
                var c = Gdk.RGBA();
                if (c.parse(s) && c.alpha > 0) return "#%02x%02x%02x".printf((int) Math.round(c.red * 255), (int) Math.round(c.green * 255), (int) Math.round(c.blue * 255));
            }
            return null;
        }

        private static string marker(string hex) {
            return hex == "#ffe066" ? "yellow" : hex;
        }

        private static string? style_color(string style) {
            foreach (string decl in style.split(";")) {
                int colon = decl.index_of(":");
                if (colon < 0) continue;
                if (decl.substring(0, colon).strip().down() == "color") {
                    string v = decl.substring(colon + 1).strip();
                    if (v.has_prefix("#") && (v.length == 7 || v.length == 4)) return v;
                }
            }
            return null;
        }

        private void walk(Xml.Node* node) {
            for (Xml.Node* n = node; n != null; n = n->next) {
                if (n->type == Xml.ElementType.TEXT_NODE || n->type == Xml.ElementType.CDATA_SECTION_NODE) {
                    add_text(n->content ?? "");
                    continue;
                }
                if (n->type != Xml.ElementType.ELEMENT_NODE) continue;
                string name = n->name.down();
                if (name == "input") {
                    checkbox(n);
                    continue;
                }
                if (name in SKIP) continue;
                string? cls = n->get_prop("class");
                if (cls != null && (cls.contains("sidebar") || cls.contains("advert") || cls.contains("cookie") || cls.contains("share-buttons"))) continue;
                element(n, name);
            }
        }

        private void element(Xml.Node* n, string name) {
            switch (name) {
                case "h1": case "h2": case "h3": case "h4": case "h5": case "h6":
                    flush();
                    current = new Block(BlockKind.heading(int.min(6, name[1] - '0' + heading_shift)));
                    walk(n->children);
                    flush();
                    return;
                case "br":
                    if (current != null && current.kind != BlockKind.PARAGRAPH) {
                        var keep = current.kind;
                        int ind = current.indent;
                        flush();
                        current = new Block(keep == BlockKind.QUOTE ? keep : BlockKind.PARAGRAPH);
                        current.indent = ind;
                    } else {
                        flush();
                    }
                    return;
                case "hr":
                    flush();
                    blocks.add(new Block(BlockKind.RULE));
                    return;
                case "ul":
                case "ol":
                    flush();
                    list_depth++;
                    list_kinds.add(name == "ol" ? BlockKind.NUMBERED : BlockKind.BULLET);
                    walk(n->children);
                    flush();
                    list_kinds.remove_at(list_kinds.size - 1);
                    list_depth--;
                    return;
                case "li":
                    flush();
                    ensure_block();
                    walk(n->children);
                    flush();
                    return;
                case "blockquote":
                    flush();
                    current = new Block(BlockKind.QUOTE);
                    walk(n->children);
                    flush();
                    return;
                case "pre":
                    flush();
                    in_pre = true;
                    walk(n->children);
                    flush();
                    in_pre = false;
                    return;
                case "img":
                    string? src = n->get_prop("src");
                    if (src == null || src == "") src = n->get_prop("data-src");
                    if (src == null || src == "") return;
                    flush();
                    var b = new Block(BlockKind.IMAGE);
                    b.alt = n->get_prop("alt") ?? "";
                    b.image = absolute(src);
                    int iw = int.parse(n->get_prop("width") ?? "0");
                    if (iw > 0 && iw < 4000) b.width = iw;
                    blocks.add(b);
                    images.add(new HtmlImage(b.image, b));
                    return;
                case "en-media":
                    flush();
                    var m = new Block(BlockKind.IMAGE);
                    m.alt = n->get_prop("type") ?? "";
                    m.image = "enex-hash:" + (n->get_prop("hash") ?? "");
                    blocks.add(m);
                    images.add(new HtmlImage(m.image, m));
                    return;
                case "en-todo":
                    flush();
                    current = new Block(BlockKind.CHECK);
                    current.checked = n->get_prop("checked") == "true";
                    return;
                case "input":
                    return;
                case "table":
                    flush();
                    table(n);
                    return;
                case "a":
                    string saved = href;
                    string? h = n->get_prop("href");
                    if (h != null && !h.has_prefix("javascript:") && !h.has_prefix("#")) href = absolute(h).replace(" ", "%20").replace(")", "%29");
                    walk(n->children);
                    href = saved;
                    return;
                case "b": case "strong":
                    bool ob = bold;
                    bold = true;
                    walk(n->children);
                    bold = ob;
                    return;
                case "i": case "em": case "cite":
                    bool oi = italic;
                    italic = true;
                    walk(n->children);
                    italic = oi;
                    return;
                case "u": case "ins":
                    bool ou = underline;
                    underline = true;
                    walk(n->children);
                    underline = ou;
                    return;
                case "s": case "del": case "strike":
                    bool os = strike;
                    strike = true;
                    walk(n->children);
                    strike = os;
                    return;
                case "code": case "kbd": case "samp": case "tt":
                    if (in_pre) {
                        walk(n->children);
                        return;
                    }
                    bool oc = code;
                    code = true;
                    walk(n->children);
                    code = oc;
                    return;
                case "mark":
                    string oh = highlight;
                    highlight = marker(hex_of(style_prop(n->get_prop("style"), "background-color") ?? style_prop(n->get_prop("style"), "background")) ?? "yellow");
                    walk(n->children);
                    highlight = oh;
                    return;
                case "span":
                case "font":
                    string ocol = color;
                    string ohl = highlight;
                    bool sb = bold, si = italic, su = underline, ss = strike;
                    string? style = n->get_prop("style");
                    string? c = style != null ? style_color(style) : null;
                    if (c == null && style != null) c = hex_of(style_prop(style, "color"));
                    if (c == null && name == "font") c = n->get_prop("color");
                    if (c != null) color = c;
                    string? bg = hex_of(style_prop(style, "background-color") ?? style_prop(style, "background"));
                    if (bg != null && bg != "#ffffff") highlight = marker(bg);
                    string? fw = style_prop(style, "font-weight");
                    if (fw != null) bold = fw == "bold" || fw == "bolder" || int.parse(fw) >= 600;
                    string? fs = style_prop(style, "font-style");
                    if (fs != null) italic = fs == "italic" || fs == "oblique";
                    string? td = style_prop(style, "text-decoration") ?? style_prop(style, "text-decoration-line");
                    if (td != null && td.contains("underline")) underline = true;
                    if (td != null && td.contains("line-through")) strike = true;
                    walk(n->children);
                    color = ocol;
                    highlight = ohl;
                    bold = sb;
                    italic = si;
                    underline = su;
                    strike = ss;
                    return;
                default:
                    if (name in BLOCKS) {
                        flush();
                        walk(n->children);
                        flush();
                    } else {
                        walk(n->children);
                    }
                    return;
            }
        }

        private void table(Xml.Node* n) {
            var t = new TableData();
            collect_rows(n->children, t);
            if (t.rows.size == 0) return;
            t.normalize();
            if (t.columns == 1 && t.rows.size <= 1) {
                current = new Block(BlockKind.PARAGRAPH);
                current.add(new Span(t.cell(0, 0)));
                flush();
                return;
            }
            var b = new Block(BlockKind.TABLE);
            b.table = t;
            blocks.add(b);
        }

        private void collect_rows(Xml.Node* node, TableData t) {
            for (Xml.Node* n = node; n != null; n = n->next) {
                if (n->type != Xml.ElementType.ELEMENT_NODE) continue;
                string name = n->name.down();
                if (name == "tr") {
                    var row = new Gee.ArrayList<string>();
                    int r = t.rows.size;
                    for (Xml.Node* c = n->children; c != null; c = c->next) {
                        if (c->type != Xml.ElementType.ELEMENT_NODE) continue;
                        string cn = c->name.down();
                        if (cn != "td" && cn != "th") continue;
                        string? style = c->get_prop("style");
                        string? bg = hex_of(style_prop(style, "background-color") ?? style_prop(style, "background"));
                        if (bg != null && bg != "#ffffff") t.set_shade(r, row.size, bg);
                        string? align = style_prop(style, "text-align") ?? c->get_prop("align");
                        if (align != null && (align == "right" || align == "center")) {
                            while (t.aligns.size <= row.size) t.aligns.add("");
                            if (t.aligns[row.size] == "") t.aligns[row.size] = align;
                        }
                        row.add(collapse(c->get_content()).strip());
                    }
                    if (row.size > 0) t.rows.add(row);
                } else if (name == "thead" || name == "tbody" || name == "tfoot") {
                    collect_rows(n->children, t);
                }
            }
        }
    }
}
