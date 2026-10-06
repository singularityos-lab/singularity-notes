namespace Singularity.Apps.Notes {

    public class PageMeta : Object {
        public int level { get; set; default = 0; }
        public double order { get; set; default = 0; }
        public string layout { get; set; default = ""; }
        public string background { get; set; default = ""; }
        public string rule { get; set; default = ""; }
        public string ink { get; set; default = ""; }
        public int canvas_height { get; set; default = 0; }
        public Gee.HashMap<string, string> extra = new Gee.HashMap<string, string>();

        public bool is_canvas {
            get { return layout == "canvas"; }
        }

        public bool is_default() {
            return level == 0 && order == 0 && layout == "" && background == "" && rule == "" && ink == "" && canvas_height == 0 && extra.size == 0;
        }

        public PageMeta copy() {
            var m = new PageMeta();
            m.level = level;
            m.order = order;
            m.layout = layout;
            m.background = background;
            m.rule = rule;
            m.ink = ink;
            m.canvas_height = canvas_height;
            foreach (var e in extra.entries) m.extra[e.key] = e.value;
            return m;
        }

        public static bool is_meta_line(string line) {
            string s = line.strip();
            return s.has_prefix("<!-- page") && s.has_suffix("-->");
        }

        public static PageMeta parse_line(string line) {
            var m = new PageMeta();
            string s = line.strip();
            s = s.substring(9, s.length - 9 - 3).strip();
            foreach (string part in s.split(" ")) {
                int eq = part.index_of("=");
                if (eq <= 0) continue;
                string k = part.substring(0, eq);
                string v = Uri.unescape_string(part.substring(eq + 1)) ?? "";
                switch (k) {
                    case "level": m.level = int.parse(v).clamp(0, 2); break;
                    case "order": m.order = double.parse(v); break;
                    case "layout": m.layout = v; break;
                    case "bg": m.background = v; break;
                    case "rule": m.rule = v; break;
                    case "ink": m.ink = v; break;
                    case "height": m.canvas_height = int.parse(v); break;
                    default: m.extra[k] = v; break;
                }
            }
            return m;
        }

        private static string enc(string v) {
            return Uri.escape_string(v, "/:#.,", false);
        }

        public string to_line() {
            var sb = new StringBuilder("<!-- page");
            if (level > 0) sb.append(" level=%d".printf(level));
            if (order != 0) sb.append(" order=%s".printf(format_order(order)));
            if (layout != "") sb.append(" layout=" + enc(layout));
            if (background != "") sb.append(" bg=" + enc(background));
            if (rule != "") sb.append(" rule=" + enc(rule));
            if (ink != "") sb.append(" ink=" + enc(ink));
            if (canvas_height > 0) sb.append(" height=%d".printf(canvas_height));
            var keys = new Gee.ArrayList<string>();
            keys.add_all(extra.keys);
            keys.sort();
            foreach (string k in keys) sb.append(" %s=%s".printf(k, enc(extra[k])));
            sb.append(" -->");
            return sb.str;
        }

        public static string format_order(double v) {
            if (v == Math.floor(v) && v.abs() < 1e15) return "%.0f".printf(v);
            char[] buf = new char[double.DTOSTR_BUF_SIZE];
            return v.to_str(buf);
        }
    }

    public class Container : Object {
        public int x { get; set; default = 40; }
        public int y { get; set; default = 40; }
        public int width { get; set; default = 480; }
        public string markdown { get; set; default = ""; }

        public Container(int x, int y, int width, string markdown) {
            Object(x: x, y: y, width: width, markdown: markdown);
        }
    }

    public class PageDoc : Object {
        public string title { get; set; default = ""; }
        public string body { get; set; default = ""; }
        public PageMeta meta = new PageMeta();
        public Gee.ArrayList<Container> containers = new Gee.ArrayList<Container>();
        public bool trailing_newline = false;

        public static PageDoc parse(string text) {
            var doc = new PageDoc();
            string t = text.replace("\r\n", "\n");
            doc.trailing_newline = t.has_suffix("\n");
            if (doc.trailing_newline) t = t.substring(0, t.length - 1);
            string[] lines = t.split("\n");
            var kept = new Gee.ArrayList<string>();
            foreach (string line in lines) {
                if (PageMeta.is_meta_line(line)) {
                    doc.meta = PageMeta.parse_line(line);
                    continue;
                }
                kept.add(line);
            }
            while (kept.size > 0 && kept[kept.size - 1] == "" && lines.length > kept.size) kept.remove_at(kept.size - 1);
            int start = 0;
            if (kept.size > 0 && kept[0].has_prefix("# ") && !kept[0].contains("<!--")) {
                var probe = RichText.parse(kept[0]);
                doc.title = probe.size > 0 ? probe[0].plain_text() : kept[0].substring(2);
                start = 1;
            }
            var body_lines = new Gee.ArrayList<string>();
            for (int i = start; i < kept.size; i++) body_lines.add(kept[i]);
            if (doc.meta.is_canvas) doc.split_containers(body_lines);
            else doc.body = join(body_lines);
            return doc;
        }

        private static string join(Gee.List<string> lines) {
            var sb = new StringBuilder();
            for (int i = 0; i < lines.size; i++) {
                if (i > 0) sb.append("\n");
                sb.append(lines[i]);
            }
            return sb.str;
        }

        private void split_containers(Gee.List<string> lines) {
            containers.clear();
            Container? current = null;
            var buf = new Gee.ArrayList<string>();
            var loose = new Gee.ArrayList<string>();
            foreach (string line in lines) {
                string s = line.strip();
                if (current == null && s.has_prefix("<!-- block") && s.has_suffix("-->")) {
                    string attrs = s.substring(10, s.length - 13);
                    current = new Container(int.parse(RichText.attr(attrs, "x")), int.parse(RichText.attr(attrs, "y")),
                                            int.max(80, int.parse(RichText.attr(attrs, "w"))), "");
                    buf.clear();
                    continue;
                }
                if (current != null && s == "<!-- /block -->") {
                    current.markdown = join(buf);
                    containers.add(current);
                    current = null;
                    continue;
                }
                if (current != null) buf.add(line);
                else if (s != "") loose.add(line);
            }
            if (current != null) {
                current.markdown = join(buf);
                containers.add(current);
            }
            if (loose.size > 0) {
                int y = 40;
                foreach (var c in containers) y = int.max(y, c.y + 120);
                containers.add(new Container(40, y, 560, join(loose)));
            }
        }

        public string serialize() {
            var sb = new StringBuilder();
            if (title.strip() != "") {
                var b = new Block(BlockKind.HEADING1);
                b.add(new Span(title.replace("\n", " ")));
                sb.append(RichText.render_block(b));
            }
            string content;
            if (meta.is_canvas) {
                var cb = new StringBuilder();
                bool first = true;
                foreach (var c in containers) {
                    if (c.markdown.strip() == "") continue;
                    if (!first) cb.append("\n");
                    first = false;
                    cb.append("<!-- block x=\"%d\" y=\"%d\" w=\"%d\" -->\n".printf(c.x, c.y, c.width));
                    cb.append(c.markdown);
                    cb.append("\n<!-- /block -->");
                }
                content = cb.str;
            } else {
                content = body;
            }
            if (sb.len > 0 && (content != "" || !meta.is_default())) sb.append("\n");
            sb.append(content);
            if (!meta.is_default()) {
                if (sb.len > 0) sb.append("\n");
                sb.append(meta.to_line());
            }
            if (trailing_newline) sb.append("\n");
            return sb.str;
        }

        public string plain_text() {
            var sb = new StringBuilder();
            if (title != "") sb.append(title + "\n");
            if (meta.is_canvas) foreach (var c in containers) sb.append(RichText.plain(c.markdown));
            else sb.append(RichText.plain(body));
            return sb.str;
        }

        public string flow_markdown() {
            if (!meta.is_canvas) return body;
            var sorted = new Gee.ArrayList<Container>();
            sorted.add_all(containers);
            sorted.sort((a, b) => a.y != b.y ? a.y - b.y : a.x - b.x);
            var sb = new StringBuilder();
            foreach (var c in sorted) {
                if (c.markdown.strip() == "") continue;
                if (sb.len > 0) sb.append("\n\n");
                sb.append(c.markdown);
            }
            return sb.str;
        }

        public static string title_of(string text) {
            var d = parse(text);
            if (d.title != "") return d.title;
            foreach (string line in d.flow_markdown().split("\n")) {
                if (line.strip() == "" || line.strip().has_prefix("<!--")) continue;
                var bl = RichText.parse(line);
                if (bl.size == 0) continue;
                string t = bl[0].kind.is_object() ? "" : bl[0].plain_text().strip();
                if (t != "") return t;
            }
            return "";
        }

        public static string snippet_of(string text) {
            var d = parse(text);
            var sb = new StringBuilder();
            bool skip_first = d.title == "";
            foreach (string line in RichText.plain(d.flow_markdown()).split("\n")) {
                string t = line.strip();
                if (t == "") continue;
                if (skip_first) {
                    skip_first = false;
                    continue;
                }
                if (sb.len > 0) sb.append(" ");
                sb.append(t);
                if (sb.len > 160) break;
            }
            return sb.str;
        }
    }
}
