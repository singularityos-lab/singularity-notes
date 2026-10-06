namespace Singularity.Apps.Notes {

    public enum BlockKind {
        PARAGRAPH,
        HEADING1,
        HEADING2,
        HEADING3,
        HEADING4,
        HEADING5,
        HEADING6,
        QUOTE,
        CODE,
        CHECK,
        BULLET,
        NUMBERED,
        IMAGE,
        FILE,
        TABLE,
        INK,
        EQUATION,
        RECORDING,
        RULE;

        public int heading_level() {
            switch (this) {
                case HEADING1: return 1;
                case HEADING2: return 2;
                case HEADING3: return 3;
                case HEADING4: return 4;
                case HEADING5: return 5;
                case HEADING6: return 6;
                default: return 0;
            }
        }

        public static BlockKind heading(int level) {
            switch (level) {
                case 1: return HEADING1;
                case 2: return HEADING2;
                case 3: return HEADING3;
                case 4: return HEADING4;
                case 5: return HEADING5;
                case 6: return HEADING6;
                default: return PARAGRAPH;
            }
        }

        public bool is_list() {
            return this == CHECK || this == BULLET || this == NUMBERED;
        }

        public bool is_object() {
            return this == IMAGE || this == FILE || this == TABLE || this == INK || this == EQUATION || this == RECORDING || this == RULE;
        }
    }

    public class Span : Object {
        public string text { get; set; default = ""; }
        public bool bold { get; set; default = false; }
        public bool italic { get; set; default = false; }
        public string href { get; set; default = ""; }
        public bool underline { get; set; default = false; }
        public bool strike { get; set; default = false; }
        public bool code { get; set; default = false; }
        public string highlight { get; set; default = ""; }
        public string color { get; set; default = ""; }
        public string font { get; set; default = ""; }
        public int size { get; set; default = 0; }

        public Span(string text, bool bold = false, bool italic = false, string href = "") {
            Object(text: text, bold: bold, italic: italic, href: href);
        }

        public Span with_text(string t) {
            var s = new Span(t, bold, italic, href);
            s.underline = underline;
            s.strike = strike;
            s.code = code;
            s.highlight = highlight;
            s.color = color;
            s.font = font;
            s.size = size;
            return s;
        }

        public bool same_style(Span other) {
            return bold == other.bold && italic == other.italic && href == other.href && underline == other.underline
                && strike == other.strike && code == other.code && highlight == other.highlight && color == other.color
                && font == other.font && size == other.size;
        }

        public bool has_style_span() {
            return color != "" || font != "" || size > 0;
        }
    }

    public class TableData : Object {
        public Gee.ArrayList<Gee.ArrayList<string>> rows = new Gee.ArrayList<Gee.ArrayList<string>>();
        public Gee.ArrayList<string> aligns = new Gee.ArrayList<string>();
        public Gee.HashMap<string, string> shading = new Gee.HashMap<string, string>();

        public int columns {
            get {
                int c = 0;
                foreach (var r in rows) c = int.max(c, r.size);
                return c;
            }
        }

        public void normalize() {
            int c = int.max(1, columns);
            if (rows.size == 0) rows.add(new Gee.ArrayList<string>());
            foreach (var r in rows) while (r.size < c) r.add("");
            while (aligns.size < c) aligns.add("");
            while (aligns.size > c) aligns.remove_at(aligns.size - 1);
        }

        public string cell(int r, int c) {
            if (r < 0 || r >= rows.size || c < 0 || c >= rows[r].size) return "";
            return rows[r][c];
        }

        public string shade(int r, int c) {
            return shading["%d:%d".printf(r, c)] ?? "";
        }

        public void set_shade(int r, int c, string color) {
            string key = "%d:%d".printf(r, c);
            if (color == "") shading.unset(key);
            else shading[key] = color;
        }

        public TableData copy() {
            var t = new TableData();
            foreach (var r in rows) {
                var nr = new Gee.ArrayList<string>();
                nr.add_all(r);
                t.rows.add(nr);
            }
            t.aligns.add_all(aligns);
            foreach (var e in shading.entries) t.shading[e.key] = e.value;
            return t;
        }

        public void sort_by(int column, bool descending, bool keep_header) {
            if (rows.size < 2) return;
            int first = keep_header ? 1 : 0;
            var body = new Gee.ArrayList<Gee.ArrayList<string>>();
            var shades = new Gee.ArrayList<Gee.HashMap<int, string>>();
            for (int i = first; i < rows.size; i++) {
                body.add(rows[i]);
                var m = new Gee.HashMap<int, string>();
                for (int c = 0; c < rows[i].size; c++) {
                    string s = shade(i, c);
                    if (s != "") m[c] = s;
                }
                shades.add(m);
            }
            var order = new Gee.ArrayList<int>();
            for (int i = 0; i < body.size; i++) order.add(i);
            order.sort((a, b) => {
                int r = compare_cells(body[a].size > column ? body[a][column] : "", body[b].size > column ? body[b][column] : "");
                if (r == 0) r = a - b;
                return descending ? -r : r;
            });
            for (int i = first; i < rows.size; i++) for (int c = 0; c < rows[i].size; c++) set_shade(i, c, "");
            for (int i = 0; i < order.size; i++) {
                rows[first + i] = body[order[i]];
                foreach (var e in shades[order[i]].entries) set_shade(first + i, e.key, e.value);
            }
        }

        public static int compare_cells(string a, string b) {
            double x, y;
            bool nx = double.try_parse(a.strip().replace(",", "."), out x);
            bool ny = double.try_parse(b.strip().replace(",", "."), out y);
            if (nx && ny && a.strip() != "" && b.strip() != "") return x < y ? -1 : (x > y ? 1 : 0);
            return a.casefold().collate(b.casefold());
        }

        public string to_csv() {
            var sb = new StringBuilder();
            foreach (var r in rows) {
                bool first = true;
                foreach (string c in r) {
                    if (!first) sb.append(",");
                    first = false;
                    if (c.contains(",") || c.contains("\"") || c.contains("\n")) sb.append("\"%s\"".printf(c.replace("\"", "\"\"")));
                    else sb.append(c);
                }
                sb.append("\n");
            }
            return sb.str;
        }
    }

    public class Block : Object {
        public BlockKind kind { get; set; default = BlockKind.PARAGRAPH; }
        public bool checked { get; set; default = false; }
        public string image { get; set; default = ""; }
        public string alt { get; set; default = ""; }
        public int width { get; set; default = 0; }
        public int indent { get; set; default = 0; }
        public string anchor { get; set; default = ""; }
        public string lang { get; set; default = ""; }
        public string raw { get; set; default = ""; }
        public string[] tags = {};
        public TableData? table = null;
        public Gee.ArrayList<Span> spans = new Gee.ArrayList<Span>();

        public Block(BlockKind kind) {
            Object(kind: kind);
        }

        public string plain_text() {
            if (kind == BlockKind.TABLE && table != null) {
                var sb = new StringBuilder();
                foreach (var r in table.rows) {
                    sb.append(string.joinv("\t", r.to_array()));
                    sb.append("\n");
                }
                return sb.str.strip();
            }
            if (kind == BlockKind.CODE) return raw;
            var sb = new StringBuilder();
            foreach (var s in spans) sb.append(s.text);
            return sb.str;
        }

        public void add(Span span) {
            if (span.text == "") return;
            if (spans.size > 0 && spans[spans.size - 1].same_style(span)) {
                var last = spans[spans.size - 1];
                last.text = last.text + span.text;
                return;
            }
            spans.add(span);
        }

        public bool has_tag(string tag) {
            return tag in tags;
        }
    }

    public class RichText : Object {
        public const string ESCAPABLE = "\\*_[]()!#-<>~=`|&+.";

        private static Regex? image_re = null;
        private static Regex? img_html_re = null;
        private static Regex? file_re = null;
        private static Regex? anchor_re = null;
        private static Regex? number_re = null;
        private static Regex? shading_re = null;

        private static void ensure_regex() {
            if (image_re != null) return;
            try {
                image_re = new Regex("^!\\[((?:[^\\]\\\\]|\\\\.)*)\\]\\(([^)\\s]+)\\)\\s*$");
                img_html_re = new Regex("^<img\\s+([^>]*?)/?>\\s*$");
                file_re = new Regex("^\\[((?:[^\\]\\\\]|\\\\.)*)\\]\\((attachments/[^)\\s]+)\\)\\s*$");
                anchor_re = new Regex("\\s?<a id=\"([A-Za-z0-9_-]+)\"></a>\\s*$");
                number_re = new Regex("^(\\d{1,9})[.)] ");
                shading_re = new Regex("^<!-- table( [^>]*)? -->$");
            } catch (RegexError e) {
                error("%s", e.message);
            }
        }

        public static string attr(string attrs, string name) {
            try {
                var re = new Regex(name + "=\"([^\"]*)\"");
                MatchInfo info;
                if (re.match(attrs, 0, out info)) return info.fetch(1);
            } catch (RegexError e) {
            }
            return "";
        }

        private static int leading_spaces(string line) {
            int n = 0;
            while (n < line.length && (line[n] == ' ' || line[n] == '\t')) n += line[n] == '\t' ? 4 : 1;
            return n;
        }

        private static bool is_list_line(string s) {
            if (s.has_prefix("- ") || s.has_prefix("* ") || s.has_prefix("+ ")) return true;
            MatchInfo info;
            return number_re.match(s, 0, out info);
        }

        private static int indent_unit(string[] lines) {
            int unit = 0;
            foreach (string line in lines) {
                int n = 0;
                while (n < line.length && line[n] == ' ') n++;
                if (n == 0 || n >= line.length) continue;
                if (!is_list_line(line.substring(n))) continue;
                if (unit == 0 || n < unit) unit = n;
            }
            return unit < 2 ? 4 : int.min(unit, 4);
        }

        public static bool is_table_separator(string line) {
            string s = line.strip();
            if (!s.has_prefix("|") && !s.contains("|")) return false;
            bool dash = false;
            for (int i = 0; i < s.length; i++) {
                char c = s[i];
                if (c == '-') dash = true;
                else if (c != '|' && c != ':' && c != ' ') return false;
            }
            return dash;
        }

        public static Gee.ArrayList<string> split_row(string line) {
            var cells = new Gee.ArrayList<string>();
            string s = line.strip();
            if (s.has_prefix("|")) s = s.substring(1);
            if (s.has_suffix("|") && !s.has_suffix("\\|")) s = s.substring(0, s.length - 1);
            var buf = new StringBuilder();
            for (int i = 0; i < s.length; i++) {
                if (s[i] == '\\' && i + 1 < s.length && s[i + 1] == '|') {
                    buf.append_c('|');
                    i++;
                    continue;
                }
                if (s[i] == '|') {
                    cells.add(buf.str.strip().replace("<br>", "\n"));
                    buf.truncate(0);
                    continue;
                }
                buf.append_c(s[i]);
            }
            cells.add(buf.str.strip().replace("<br>", "\n"));
            return cells;
        }

        public static Gee.ArrayList<Block> parse(string markdown) {
            ensure_regex();
            var blocks = new Gee.ArrayList<Block>();
            string text = markdown.replace("\r\n", "\n");
            if (text.has_suffix("\n")) text = text.substring(0, text.length - 1);
            string[] lines = text.split("\n");
            int unit = indent_unit(lines);
            string shading = "";
            for (int i = 0; i < lines.length; i++) {
                string line = lines[i];
                string st = line.strip();
                MatchInfo sm;
                if (shading_re.match(st, 0, out sm) && i + 1 < lines.length && lines[i + 1].strip().has_prefix("|")) {
                    shading = sm.fetch(1) ?? "";
                    continue;
                }
                if (line.has_prefix("```")) {
                    string lang = line.substring(3).strip();
                    int j = i + 1;
                    bool closed = false;
                    var code = new Gee.ArrayList<string>();
                    while (j < lines.length) {
                        if (lines[j].strip() == "```") {
                            closed = true;
                            break;
                        }
                        code.add(lines[j]);
                        j++;
                    }
                    if (closed) {
                        if (code.size == 0) code.add("");
                        for (int k = 0; k < code.size; k++) {
                            var b = new Block(BlockKind.CODE);
                            b.raw = code[k];
                            if (k == 0) b.lang = lang;
                            blocks.add(b);
                        }
                        i = j;
                        continue;
                    }
                }
                if (st.has_prefix("|") && i + 1 < lines.length && is_table_separator(lines[i + 1])) {
                    var b = new Block(BlockKind.TABLE);
                    b.table = new TableData();
                    b.table.rows.add(split_row(line));
                    foreach (string a in split_row(lines[i + 1])) {
                        bool l = a.has_prefix(":");
                        bool r = a.has_suffix(":");
                        b.table.aligns.add(l && r ? "center" : (r ? "right" : (l ? "left" : "")));
                    }
                    int j = i + 2;
                    while (j < lines.length && lines[j].strip().has_prefix("|")) {
                        b.table.rows.add(split_row(lines[j]));
                        j++;
                    }
                    parse_shading(shading, b.table);
                    shading = "";
                    b.table.normalize();
                    blocks.add(b);
                    i = j - 1;
                    continue;
                }
                shading = "";
                blocks.add(parse_line(line, unit));
            }
            if (blocks.size == 0) blocks.add(new Block(BlockKind.PARAGRAPH));
            return blocks;
        }

        private static void parse_shading(string attrs, TableData t) {
            string s = attr(attrs, "shading");
            if (s == "") return;
            foreach (string part in s.split(",")) {
                string[] f = part.split(":");
                if (f.length != 3) continue;
                t.set_shade(int.parse(f[0]), int.parse(f[1]), f[2]);
            }
        }

        private static string take_anchor(string line, out string anchor) {
            anchor = "";
            MatchInfo info;
            if (anchor_re.match(line, 0, out info)) {
                anchor = info.fetch(1);
                int start, end;
                info.fetch_pos(0, out start, out end);
                return line.substring(0, start);
            }
            return line;
        }

        private static string take_tags(string text, out string[] tags) {
            string[] found = {};
            string s = text;
            while (s.has_prefix("[!")) {
                int close = s.index_of("]");
                if (close < 3) break;
                string name = s.substring(2, close - 2);
                bool ok = true;
                for (int k = 0; k < name.length; k++) {
                    char c = name[k];
                    if (!(c.isalnum() || c == '-' || c == '_')) ok = false;
                }
                if (!ok) break;
                found += name.down();
                s = s.substring(close + 1);
                if (s.has_prefix(" ")) s = s.substring(1);
            }
            tags = found;
            return s;
        }

        private static Block parse_line(string raw_line, int unit) {
            string anchor;
            string line = take_anchor(raw_line, out anchor);
            Block b;
            string st = line.strip();
            MatchInfo info;
            if (image_re.match(st, 0, out info)) {
                b = image_block(unescape(info.fetch(1)), info.fetch(2), 0);
                b.anchor = anchor;
                return b;
            }
            if (img_html_re.match(st, 0, out info)) {
                string attrs = info.fetch(1);
                string src = attr(attrs, "src");
                if (src != "") {
                    b = image_block(html_unescape(attr(attrs, "alt")), src, int.parse(attr(attrs, "width")));
                    b.anchor = anchor;
                    return b;
                }
            }
            if (file_re.match(st, 0, out info)) {
                string target = info.fetch(2);
                string name = Path.get_basename(target);
                b = new Block(name.has_prefix("recording-") ? BlockKind.RECORDING : BlockKind.FILE);
                b.alt = unescape(info.fetch(1));
                b.image = target;
                b.anchor = anchor;
                return b;
            }
            if (st == "---" || st == "***" || st == "___") {
                b = new Block(BlockKind.RULE);
                return b;
            }
            int spaces = leading_spaces(line);
            string rest = line.substring(int.min(line.length, count_ws_bytes(line)));
            int level = 0;
            while (level < 6 && rest.has_prefix("#")) {
                level++;
                rest = rest.substring(1);
            }
            if (level > 0 && rest.has_prefix(" ") && spaces == 0) {
                b = new Block(BlockKind.heading(level));
                rest = rest.substring(1);
            } else {
                rest = line.substring(int.min(line.length, count_ws_bytes(line)));
                if (rest.has_prefix("> ") || rest == ">") {
                    b = new Block(BlockKind.QUOTE);
                    rest = rest.length > 2 ? rest.substring(2) : "";
                } else if (rest.has_prefix("- [ ] ") || rest.has_prefix("- [x] ") || rest.has_prefix("- [X] ")
                           || rest.has_prefix("* [ ] ") || rest.has_prefix("* [x] ") || rest == "- [ ]" || rest == "- [x]") {
                    b = new Block(BlockKind.CHECK);
                    b.checked = rest[3] != ' ';
                    rest = rest.length > 6 ? rest.substring(6) : "";
                    b.indent = spaces / unit;
                } else if (rest.has_prefix("- ") || rest.has_prefix("* ") || rest.has_prefix("+ ")) {
                    b = new Block(BlockKind.BULLET);
                    rest = rest.substring(2);
                    b.indent = spaces / unit;
                } else if (number_re.match(rest, 0, out info)) {
                    b = new Block(BlockKind.NUMBERED);
                    rest = rest.substring(info.fetch(0).length);
                    b.indent = spaces / unit;
                } else {
                    b = new Block(BlockKind.PARAGRAPH);
                    int em = 0;
                    while (rest.has_prefix("&emsp;")) {
                        em++;
                        rest = rest.substring(6);
                    }
                    b.indent = em;
                }
            }
            string[] tags;
            rest = take_tags(rest, out tags);
            b.tags = tags;
            b.anchor = anchor;
            parse_inline(rest, b);
            return b;
        }

        private static int count_ws_bytes(string line) {
            int n = 0;
            while (n < line.length && (line[n] == ' ' || line[n] == '\t')) n++;
            return n;
        }

        public static Block image_block(string alt, string path, int width) {
            string name = Path.get_basename(path);
            BlockKind kind = BlockKind.IMAGE;
            if (name.has_prefix("ink-") && name.has_suffix(".svg")) kind = BlockKind.INK;
            else if (name.has_prefix("equation-")) kind = BlockKind.EQUATION;
            var b = new Block(kind);
            b.alt = alt;
            b.image = path;
            b.width = width;
            return b;
        }

        private class InlineState {
            public bool bold;
            public bool italic;
            public bool underline;
            public bool strike;
            public string highlight = "";
            public Gee.ArrayList<string> styles = new Gee.ArrayList<string>();

            public Span make(string text, string href = "") {
                var s = new Span(text, bold, italic, href);
                s.underline = underline;
                s.strike = strike;
                s.highlight = highlight;
                foreach (string st in styles) apply_style(s, st);
                return s;
            }
        }

        private static void apply_style(Span s, string style) {
            foreach (string decl in style.split(";")) {
                int colon = decl.index_of(":");
                if (colon < 0) continue;
                string k = decl.substring(0, colon).strip().down();
                string v = decl.substring(colon + 1).strip();
                switch (k) {
                    case "color": s.color = v; break;
                    case "background":
                    case "background-color": s.highlight = v; break;
                    case "font-family": s.font = v.replace("'", "").replace("\"", ""); break;
                    case "font-size": s.size = int.parse(v.replace("pt", "").replace("px", "")); break;
                    default: break;
                }
            }
        }

        public static void parse_inline(string text, Block into) {
            var st = new InlineState();
            int i = 0;
            var buf = new StringBuilder();
            while (i < text.length) {
                char c = text[i];
                if (c == '\\' && i + 1 < text.length && ESCAPABLE.index_of_char(text[i + 1]) >= 0) {
                    buf.append_c(text[i + 1]);
                    i += 2;
                    continue;
                }
                if (c == '`') {
                    int close = text.index_of("`", i + 1);
                    if (close > i + 1) {
                        into.add(st.make(buf.str));
                        buf.truncate(0);
                        var s = st.make(text.substring(i + 1, close - i - 1));
                        s.code = true;
                        into.add(s);
                        i = close + 1;
                        continue;
                    }
                }
                if (c == '<') {
                    string rest = text.substring(i);
                    int consumed = 0;
                    if (rest.has_prefix("<u>")) {
                        into.add(st.make(buf.str));
                        buf.truncate(0);
                        st.underline = true;
                        consumed = 3;
                    } else if (rest.has_prefix("</u>")) {
                        into.add(st.make(buf.str));
                        buf.truncate(0);
                        st.underline = false;
                        consumed = 4;
                    } else if (rest.has_prefix("<mark>")) {
                        into.add(st.make(buf.str));
                        buf.truncate(0);
                        st.highlight = "yellow";
                        consumed = 6;
                    } else if (rest.has_prefix("<mark style=\"")) {
                        int end = rest.index_of("\">");
                        if (end > 0) {
                            into.add(st.make(buf.str));
                            buf.truncate(0);
                            var probe = new Span("");
                            apply_style(probe, rest.substring(13, end - 13));
                            st.highlight = probe.highlight != "" ? probe.highlight : "yellow";
                            consumed = end + 2;
                        }
                    } else if (rest.has_prefix("</mark>")) {
                        into.add(st.make(buf.str));
                        buf.truncate(0);
                        st.highlight = "";
                        consumed = 7;
                    } else if (rest.has_prefix("<span style=\"")) {
                        int end = rest.index_of("\">");
                        if (end > 0) {
                            into.add(st.make(buf.str));
                            buf.truncate(0);
                            st.styles.add(rest.substring(13, end - 13));
                            consumed = end + 2;
                        }
                    } else if (rest.has_prefix("</span>") && st.styles.size > 0) {
                        into.add(st.make(buf.str));
                        buf.truncate(0);
                        st.styles.remove_at(st.styles.size - 1);
                        consumed = 7;
                    } else if (rest.has_prefix("<s>") || rest.has_prefix("<del>")) {
                        into.add(st.make(buf.str));
                        buf.truncate(0);
                        st.strike = true;
                        consumed = rest.has_prefix("<s>") ? 3 : 5;
                    } else if (rest.has_prefix("</s>") || rest.has_prefix("</del>")) {
                        into.add(st.make(buf.str));
                        buf.truncate(0);
                        st.strike = false;
                        consumed = rest.has_prefix("</s>") ? 4 : 6;
                    } else if (rest.has_prefix("<br>")) {
                        buf.append_c(' ');
                        consumed = 4;
                    }
                    if (consumed > 0) {
                        i += consumed;
                        continue;
                    }
                }
                if (c == '~' && i + 1 < text.length && text[i + 1] == '~') {
                    if (st.strike || text.index_of("~~", i + 2) > i + 2) {
                        into.add(st.make(buf.str));
                        buf.truncate(0);
                        st.strike = !st.strike;
                        i += 2;
                        continue;
                    }
                }
                if (c == '=' && i + 1 < text.length && text[i + 1] == '=') {
                    if (st.highlight != "" || text.index_of("==", i + 2) > i + 2) {
                        into.add(st.make(buf.str));
                        buf.truncate(0);
                        st.highlight = st.highlight != "" ? "" : "yellow";
                        i += 2;
                        continue;
                    }
                }
                if (c == '*' && i + 1 < text.length && text[i + 1] == '*') {
                    if (st.bold || text.index_of("**", i + 2) > i + 2) {
                        into.add(st.make(buf.str));
                        buf.truncate(0);
                        st.bold = !st.bold;
                        i += 2;
                        continue;
                    }
                }
                if (c == '*' && (st.italic || has_closing_star(text, i + 1))) {
                    into.add(st.make(buf.str));
                    buf.truncate(0);
                    st.italic = !st.italic;
                    i += 1;
                    continue;
                }
                if (c == '[') {
                    int close = find_label_end(text, i + 1);
                    int end = close >= 0 ? text.index_of(")", close + 2) : -1;
                    if (close > i && end > close) {
                        string label = text.substring(i + 1, close - i - 1);
                        string href = text.substring(close + 2, end - close - 2);
                        if (!href.contains(" ")) {
                            into.add(st.make(buf.str));
                            buf.truncate(0);
                            var inner = new Block(BlockKind.PARAGRAPH);
                            parse_inline(label, inner);
                            foreach (var s in inner.spans) {
                                var merged = st.make(s.text, href);
                                merged.bold = merged.bold || s.bold;
                                merged.italic = merged.italic || s.italic;
                                merged.underline = merged.underline || s.underline;
                                merged.strike = merged.strike || s.strike;
                                if (s.highlight != "") merged.highlight = s.highlight;
                                if (s.color != "") merged.color = s.color;
                                if (s.font != "") merged.font = s.font;
                                if (s.size > 0) merged.size = s.size;
                                into.add(merged);
                            }
                            i = end + 1;
                            continue;
                        }
                    }
                }
                if (c == '&') {
                    string rest = text.substring(i);
                    string[] ents = { "&amp;", "&lt;", "&gt;", "&quot;", "&emsp;", "&nbsp;" };
                    string[] vals = { "&", "<", ">", "\"", "\u2003", "\u00a0" };
                    bool hit = false;
                    for (int k = 0; k < ents.length; k++) {
                        if (rest.has_prefix(ents[k])) {
                            buf.append(vals[k]);
                            i += ents[k].length;
                            hit = true;
                            break;
                        }
                    }
                    if (hit) continue;
                }
                buf.append_c(c);
                i++;
            }
            into.add(st.make(buf.str));
        }

        private static int find_label_end(string text, int from) {
            int depth = 0;
            for (int j = from; j < text.length - 1; j++) {
                if (text[j] == '\\') {
                    j++;
                    continue;
                }
                if (text[j] == '[') depth++;
                if (text[j] == ']') {
                    if (depth == 0) return text[j + 1] == '(' ? j : -1;
                    depth--;
                }
            }
            return -1;
        }

        private static bool has_closing_star(string text, int from) {
            if (from >= text.length || text[from] == ' ') return false;
            for (int j = from; j < text.length; j++) {
                if (text[j] == '\\') {
                    j++;
                    continue;
                }
                if (text[j] == '*') {
                    if (j + 1 < text.length && text[j + 1] == '*') {
                        j++;
                        continue;
                    }
                    return j > from;
                }
            }
            return false;
        }

        public static string unescape(string s) {
            var sb = new StringBuilder();
            for (int i = 0; i < s.length; i++) {
                if (s[i] == '\\' && i + 1 < s.length) {
                    sb.append_c(s[i + 1]);
                    i++;
                } else {
                    sb.append_c(s[i]);
                }
            }
            return sb.str;
        }

        public static string html_unescape(string s) {
            return s.replace("&quot;", "\"").replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&");
        }

        public static string html_escape(string s) {
            return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;");
        }

        public static string escape(string s) {
            var sb = new StringBuilder();
            for (int i = 0; i < s.length; i++) {
                char c = s[i];
                bool doubled = i + 1 < s.length && s[i + 1] == c;
                if (c == '\\' || c == '*' || c == '[' || c == ']' || c == '`' || c == '<') sb.append_c('\\');
                else if ((c == '~' || c == '=') && doubled) sb.append_c('\\');
                else if (c == '&' && entity_like(s, i)) sb.append_c('\\');
                sb.append_c(c);
            }
            return sb.str;
        }

        private static bool entity_like(string s, int i) {
            int semi = s.index_of(";", i);
            if (semi < 0 || semi - i > 8) return false;
            for (int j = i + 1; j < semi; j++) if (!s[j].isalnum()) return false;
            return semi > i + 1;
        }

        private static string escape_line_start(string s) {
            if (s.has_prefix("#") || s.has_prefix("- ") || s.has_prefix("* ") || s.has_prefix("+ ") || s.has_prefix("!")
                || s.has_prefix(">") || s.has_prefix("|") || s.has_prefix("---") || s.has_prefix("___") || s.has_prefix("```")
                || s.has_prefix("[!")) return "\\" + s;
            MatchInfo info;
            ensure_regex();
            if (number_re.match(s, 0, out info)) {
                string num = info.fetch(1);
                return num + "\\" + s.substring(num.length);
            }
            if (s.has_prefix(" ") || s.has_prefix("\t")) return "&nbsp;" + s.substring(1);
            return s;
        }

        private static string style_attr(Span s) {
            string[] parts = {};
            if (s.color != "") parts += "color:" + s.color;
            if (s.font != "") parts += "font-family:" + s.font;
            if (s.size > 0) parts += "font-size:%dpt".printf(s.size);
            return string.joinv(";", parts);
        }

        public static string render_inline(Gee.List<Span> spans) {
            var sb = new StringBuilder();
            bool bold = false;
            bool italic = false;
            foreach (var s in spans) {
                if (s.text == "") continue;
                if (italic && !s.italic) {
                    sb.append("*");
                    italic = false;
                }
                if (bold && !s.bold) {
                    sb.append("**");
                    bold = false;
                }
                if (!bold && s.bold) {
                    sb.append("**");
                    bold = true;
                }
                if (!italic && s.italic) {
                    sb.append("*");
                    italic = true;
                }
                var inner = new StringBuilder();
                if (s.has_style_span()) inner.append("<span style=\"%s\">".printf(style_attr(s)));
                if (s.highlight != "") inner.append(s.highlight == "yellow" ? "==" : "<mark style=\"background:%s\">".printf(s.highlight));
                if (s.underline) inner.append("<u>");
                if (s.strike) inner.append("~~");
                string body;
                if (s.code) body = "`" + s.text.replace("`", "'") + "`";
                else body = escape(s.text);
                inner.append(body);
                if (s.strike) inner.append("~~");
                if (s.underline) inner.append("</u>");
                if (s.highlight != "") inner.append(s.highlight == "yellow" ? "==" : "</mark>");
                if (s.has_style_span()) inner.append("</span>");
                if (s.href != "") sb.append("[%s](%s)".printf(inner.str, s.href));
                else sb.append(inner.str);
            }
            if (italic) sb.append("*");
            if (bold) sb.append("**");
            return sb.str;
        }

        private static string tag_prefix(Block b) {
            var sb = new StringBuilder();
            foreach (string t in b.tags) sb.append("[!%s] ".printf(t));
            return sb.str;
        }

        public static string render_block(Block b, int number = 1) {
            string anchor = b.anchor != "" ? " <a id=\"%s\"></a>".printf(b.anchor) : "";
            switch (b.kind) {
                case BlockKind.IMAGE:
                case BlockKind.INK:
                case BlockKind.EQUATION:
                    if (b.width > 0) return "<img src=\"%s\" alt=\"%s\" width=\"%d\">".printf(b.image, html_escape(b.alt), b.width) + anchor;
                    return "![%s](%s)".printf(escape(b.alt), b.image) + anchor;
                case BlockKind.FILE:
                case BlockKind.RECORDING:
                    return "[%s](%s)".printf(escape(b.alt), b.image) + anchor;
                case BlockKind.RULE:
                    return "---";
                case BlockKind.TABLE:
                    return render_table(b.table ?? new TableData());
                case BlockKind.CODE:
                    return b.raw;
                default:
                    break;
            }
            string inline = tag_prefix(b) + render_inline(b.spans);
            if (b.tags.length == 0) inline = b.kind == BlockKind.PARAGRAPH && b.indent == 0 ? escape_line_start(inline) : protect_start(inline);
            string pad = string.nfill(b.indent * 4, ' ');
            string result;
            int level = b.kind.heading_level();
            if (level > 0) result = string.nfill(level, '#') + " " + inline;
            else if (b.kind == BlockKind.QUOTE) result = "> " + inline;
            else if (b.kind == BlockKind.CHECK) result = pad + (b.checked ? "- [x] " : "- [ ] ") + inline;
            else if (b.kind == BlockKind.BULLET) result = pad + "- " + inline;
            else if (b.kind == BlockKind.NUMBERED) result = pad + "%d. ".printf(number) + inline;
            else {
                var em = new StringBuilder();
                for (int i = 0; i < b.indent; i++) em.append("&emsp;");
                result = em.str + inline;
            }
            return result + anchor;
        }

        private static string protect_start(string inline) {
            if (inline.has_prefix("[!")) return "\\" + inline;
            return inline;
        }

        public static string render_table(TableData t) {
            t.normalize();
            var sb = new StringBuilder();
            if (t.shading.size > 0) {
                string[] parts = {};
                var keys = new Gee.ArrayList<string>();
                keys.add_all(t.shading.keys);
                keys.sort();
                foreach (string k in keys) parts += k + ":" + t.shading[k];
                sb.append("<!-- table shading=\"%s\" -->\n".printf(string.joinv(",", parts)));
            }
            for (int r = 0; r < t.rows.size; r++) {
                sb.append("|");
                foreach (string c in t.rows[r]) sb.append(" %s |".printf(cell_escape(c)));
                if (r == 0) {
                    sb.append("\n|");
                    for (int c = 0; c < t.columns; c++) {
                        string a = t.aligns[c];
                        sb.append(a == "center" ? " :---: |" : a == "right" ? " ---: |" : a == "left" ? " :--- |" : " --- |");
                    }
                }
                if (r < t.rows.size - 1) sb.append("\n");
            }
            return sb.str;
        }

        private static string cell_escape(string c) {
            return c.replace("\\", "\\\\").replace("|", "\\|").replace("\n", "<br>");
        }

        public static string render(Gee.List<Block> blocks) {
            var sb = new StringBuilder();
            bool first = true;
            var counters = new int[16];
            int i = 0;
            while (i < blocks.size) {
                var b = blocks[i];
                if (!first) sb.append("\n");
                first = false;
                if (b.kind == BlockKind.CODE) {
                    sb.append("```" + b.lang + "\n");
                    int j = i;
                    while (j < blocks.size && blocks[j].kind == BlockKind.CODE && (j == i || blocks[j].lang == "")) {
                        sb.append(blocks[j].raw);
                        sb.append("\n");
                        j++;
                    }
                    sb.append("```");
                    i = j;
                    for (int k = 0; k < counters.length; k++) counters[k] = 0;
                    continue;
                }
                int level = int.min(b.indent, counters.length - 1);
                if (b.kind == BlockKind.NUMBERED) {
                    counters[level]++;
                    for (int k = level + 1; k < counters.length; k++) counters[k] = 0;
                } else if (b.kind.is_list()) {
                    for (int k = level; k < counters.length; k++) counters[k] = 0;
                } else {
                    for (int k = 0; k < counters.length; k++) counters[k] = 0;
                }
                sb.append(render_block(b, b.kind == BlockKind.NUMBERED ? counters[level] : 1));
                i++;
            }
            return sb.str;
        }

        public static string number_label(int n, int level) {
            switch (level % 3) {
                case 1:
                    var sb = new StringBuilder();
                    int v = n;
                    while (v > 0) {
                        v--;
                        sb.prepend_c((char) ('a' + v % 26));
                        v /= 26;
                    }
                    return sb.str + ".";
                case 2:
                    return roman(n) + ".";
                default:
                    return "%d.".printf(n);
            }
        }

        private static string roman(int n) {
            int[] values = { 1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1 };
            string[] symbols = { "m", "cm", "d", "cd", "c", "xc", "l", "xl", "x", "ix", "v", "iv", "i" };
            var sb = new StringBuilder();
            int v = n;
            for (int i = 0; i < values.length; i++) {
                while (v >= values[i]) {
                    sb.append(symbols[i]);
                    v -= values[i];
                }
            }
            return sb.str;
        }

        public static int[] numbering(Gee.List<Block> blocks) {
            var result = new int[blocks.size];
            var counters = new int[16];
            for (int i = 0; i < blocks.size; i++) {
                var b = blocks[i];
                int level = int.min(b.indent, counters.length - 1);
                if (b.kind == BlockKind.NUMBERED) {
                    counters[level]++;
                    for (int k = level + 1; k < counters.length; k++) counters[k] = 0;
                    result[i] = counters[level];
                } else if (b.kind.is_list()) {
                    for (int k = level; k < counters.length; k++) counters[k] = 0;
                } else {
                    for (int k = 0; k < counters.length; k++) counters[k] = 0;
                }
            }
            return result;
        }

        public static string plain(string markdown) {
            var sb = new StringBuilder();
            foreach (var b in parse(markdown)) {
                string t = b.plain_text();
                if (b.kind.is_object() && b.kind != BlockKind.TABLE) t = b.alt;
                if (t == "") continue;
                sb.append(t);
                sb.append("\n");
            }
            return sb.str;
        }
    }
}
