namespace Singularity.Apps.Notes {

    public class HwFeatures {
        public double[] data;
        public int cols;
        public double aspect;
        public bool ascender;
        public bool descender;
        public bool printed;

        public HwFeatures(int cols) {
            this.cols = cols;
            data = new double[cols * HandwritingRecognizer.F];
        }
    }

    public class HwFontMetrics {
        public string desc;
        public Gee.HashMap<string, double?> advance = new Gee.HashMap<string, double?>();
        public double xheight;
        public double ascent;
        public double descent;
        public double fallback_advance;
        public double aspect_scale = 1.0;

        public HwFontMetrics(string desc) {
            this.desc = desc;
        }
    }

    public class HwGlyph {
        public string ch;
        public Gee.ArrayList<Stroke>? strokes;
        public double[]? flat;
        public double[] cloud;
        public double top;
        public double bottom;
        public double aspect;
    }

    public class HwShape {
        public double aspect;
        public Gee.ArrayList<double?> asc;
        public Gee.ArrayList<double?> desc;
    }

    public class HwSample {
        public string text;
        public HwFeatures features;

        public HwSample(string text, HwFeatures features) {
            this.text = text;
            this.features = features;
        }
    }

    public class HwCandidate {
        public string word;
        public string text;
        public double score;
        public double[]? cuts = null;

        public HwCandidate(string word, double score) {
            this.word = word;
            this.text = word;
            this.score = score;
        }
    }

    public class HandwritingRecognizer : Object {
        public const int H = 32;
        public const int ZONES = 4;
        public const int F = 12;
        public const double[] WEIGHTS = { 1.0, 1.0, 1.0, 0.5, 0.15, 0.15, 0.15, 0.15, 0.3, 0.3, 0.3, 0.3 };
        public const int CLOUD = 32;
        public const double COL = 2.0;
        public const double WORD_OK = 0.42;
        public static double note_prior = 0.88;
        public static double sample_prior = 0.75;
        public const double NOTE_OK = 0.28;
        public const double SAMPLE_OK = 0.12;
        public static double shape_penalty_weight = 0.03;
        public static double aspect_weight = 0.03;
        public const int FULL_RANK = 40;
        public static double word_gap = 0.06;
        public const double HARD_GAP = 1.2;
        public const int MAX_SEGMENT = 8;
        public static double word_cost = 0.0;
        public static double gap_weight = 1.0;
        public static double merge_cost = 0.0;
        public static double capital_penalty = 0.03;
        public static double step_penalty = 0.0;
        public const string ASC = "bdfhklt";
        public const double BLOB_MERGE = 0.2;
        public const int REAL_VARIANTS = 1;
        public const int FLAT = 32;
        public const double UNKNOWN_SCORE = 0.4;
        public const string[] CALIBRATION = { "minimum", "hello", "world", "garden", "quick", "table", "paper", "yes", "go", "example", "notes" };
        public const string DESC = "gjpqy";
        public const string CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,!?-+=()";
        public const string[] DEFAULT_FONTS = { "Z003", "URW Chancery L", "Comic Neue", "Caveat", "Kalam", "Dancing Script", "Pacifico", "Satisfy" };
        public const string[] FALLBACK_FONTS = { "Sans Italic", "Serif Italic", "Sans Oblique" };

        private static HandwritingRecognizer? instance = null;

        public string? user_path = null;
        public int max_candidates = 400;
        public bool use_dictionary = true;
        public bool use_net = true;
        public static double note_bonus = 2.0;
        public static double oov_margin = 18.0;
        public static double symbol_margin = 4.0;
        public static double net_word_gap = 1.1;
        public static double net_min_gap = 0.3;
        public static double split_penalty = 1.0;
        public const double NET_UNKNOWN = 30.0;
        private HwNet? net = null;
        private HwLexicon? lexicon = null;
        private int lexicon_words = -1;
        private bool net_tried = false;
        public bool busy { get; private set; default = false; }
        public Gee.ArrayList<string> fonts = new Gee.ArrayList<string>();
        private Gee.ArrayList<HwFontMetrics> metrics = new Gee.ArrayList<HwFontMetrics>();
        private Gee.HashSet<string> note_words = new Gee.HashSet<string>();
        private Gee.ArrayList<string> dict_words = new Gee.ArrayList<string>();
        private Gee.HashSet<string> dict_set = new Gee.HashSet<string>();
        private bool dict_loaded = false;
        private Gee.HashMap<string, HwFeatures> cache = new Gee.HashMap<string, HwFeatures>();
        private Gee.HashMap<string, HwShape> shapes = new Gee.HashMap<string, HwShape>();
        private Gee.ArrayList<HwSample> samples = new Gee.ArrayList<HwSample>();
        private Gee.ArrayList<HwGlyph> glyphs = new Gee.ArrayList<HwGlyph>();
        private Gee.HashMap<string, Gee.ArrayList<HwGlyph>> letters = new Gee.HashMap<string, Gee.ArrayList<HwGlyph>>();
        public string letters_source { get; private set; default = ""; }

        public static HandwritingRecognizer get_default() {
            if (instance == null) {
                instance = new HandwritingRecognizer();
                instance.user_path = Path.build_filename(Environment.get_user_data_dir(), "singularity", "notes-handwriting.json");
                instance.reload_user();
            }
            return instance;
        }

        public static string? find_letters() {
            string? env = Environment.get_variable("NOTES_HANDWRITING_DATA");
            if (env != null && FileUtils.test(env, FileTest.IS_REGULAR)) return env;
            var dirs = new Gee.ArrayList<string>();
            dirs.add(Environment.get_user_data_dir());
            foreach (string d in Environment.get_system_data_dirs()) dirs.add(d);
            foreach (string d in dirs) {
                string path = Path.build_filename(d, "singularity-notes", "handwriting", "letters.json");
                if (FileUtils.test(path, FileTest.IS_REGULAR)) return path;
            }
            return null;
        }

        public static Gee.ArrayList<Stroke> decode_strokes(Json.Array arr) {
            var strokes = new Gee.ArrayList<Stroke>();
            foreach (var sn in arr.get_elements()) {
                var coords = sn.get_array();
                var st = new Stroke();
                for (uint i = 0; i + 1 < coords.get_length(); i += 2) st.points.add(new InkPoint(coords.get_int_element(i) / 100.0, coords.get_int_element(i + 1) / 100.0));
                if (st.points.size > 0) strokes.add(st);
            }
            return strokes;
        }

        public int load_letters(string path) {
            letters.clear();
            glyphs.clear();
            cache.clear();
            int n = 0;
            try {
                var parser = new Json.Parser();
                parser.load_from_file(path);
                var root = parser.get_root().get_object();
                letters_source = root.get_string_member("source") + " (" + root.get_string_member("license") + ")";
                var map = root.get_object_member("letters");
                foreach (string ch in map.get_members()) {
                    var list = new Gee.ArrayList<HwGlyph>();
                    foreach (var proto in map.get_array_member(ch).get_elements()) {
                        var g = glyph_of(ch, decode_strokes(proto.get_array()), 0, 1);
                        if (g == null) continue;
                        list.add(g);
                        n++;
                    }
                    letters[ch] = list;
                }
            } catch (Error e) {
                warning("handwriting letters: %s", e.message);
            }
            return n;
        }

        private static HwGlyph? glyph_of(string ch, Gee.ArrayList<Stroke> strokes, double baseline, double xh) {
            if (strokes.size == 0) return null;
            var g = new HwGlyph();
            g.ch = ch;
            g.strokes = strokes;
            double x0, y0, x1, y1;
            var all = new Gee.ArrayList<InkPoint>();
            foreach (var st in strokes) foreach (var p in st.points) all.add(p);
            bounds(all, out x0, out y0, out x1, out y1);
            var pts = resample_points(strokes, double.max(1e-3, double.max(x1 - x0, y1 - y0) / 40.0));
            g.cloud = cloud_of(pts, out g.aspect);
            if (g.cloud == null) return null;
            g.flat = flat_of(strokes);
            g.top = (baseline - y0) / xh;
            g.bottom = (y1 - baseline) / xh;
            return g;
        }

        public int letter_count() {
            int n = 0;
            foreach (var l in letters.values) n += l.size;
            return n;
        }

        private Gee.ArrayList<string> sources(Gee.List<string> use_fonts) {
            var list = new Gee.ArrayList<string>();
            list.add_all(use_fonts);
            if (letters.size > 0) for (int k = 0; k < REAL_VARIANTS; k++) list.add("uji:%d".printf(k));
            return list;
        }

        private Gee.ArrayList<Stroke>? real_word(string word, int variant, bool printed) {
            double size = 20;
            var result = new Gee.ArrayList<Stroke>();
            double x = 0;
            InkPoint? end = null;
            int i = 0;
            unichar c;
            while (word.get_next_char(ref i, out c)) {
                var protos = letters[c.to_string()];
                if (protos == null || protos.size == 0) return null;
                var g = protos[variant % protos.size];
                double w = 0;
                bool first = true;
                foreach (var st in g.strokes) {
                    var cp = new Stroke();
                    foreach (var p in st.points) {
                        cp.points.add(new InkPoint(x + p.x * size, p.y * size));
                        w = double.max(w, p.x);
                    }
                    if (first && !printed && end != null) {
                        var link = new Stroke();
                        link.points.add(new InkPoint(end.x, end.y));
                        link.points.add(new InkPoint(cp.points[0].x, cp.points[0].y));
                        result.add(link);
                    }
                    first = false;
                    result.add(cp);
                }
                var last = result[result.size - 1];
                end = last.points[last.points.size - 1];
                x += (w + (printed ? 0.35 : 0.12)) * size;
            }
            return result;
        }

        public static double[]? flat_of(Gee.List<Stroke> strokes) {
            var lengths = new double[strokes.size];
            double total = 0;
            for (int k = 0; k < strokes.size; k++) {
                var pts = strokes[k].points;
                for (int i = 1; i < pts.size; i++) lengths[k] += Math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y);
                total += lengths[k];
            }
            if (total <= 0) total = 1;
            var seq = new Gee.ArrayList<InkPoint>();
            for (int k = 0; k < strokes.size; k++) {
                var pts = strokes[k].points;
                if (pts.size == 0) continue;
                int n = int.max(2, (int) Math.round(FLAT * lengths[k] / total));
                if (lengths[k] <= 0) {
                    for (int i = 0; i < n; i++) seq.add(pts[0]);
                    continue;
                }
                double step = lengths[k] / (n - 1);
                int j = 1;
                double acc = 0;
                seq.add(pts[0]);
                for (int i = 1; i < n - 1; i++) {
                    double want = i * step;
                    while (j < pts.size - 1 && acc + Math.hypot(pts[j].x - pts[j - 1].x, pts[j].y - pts[j - 1].y) < want) {
                        acc += Math.hypot(pts[j].x - pts[j - 1].x, pts[j].y - pts[j - 1].y);
                        j++;
                    }
                    double seg = Math.hypot(pts[j].x - pts[j - 1].x, pts[j].y - pts[j - 1].y);
                    double t = seg > 0 ? ((want - acc) / seg).clamp(0, 1) : 0;
                    seq.add(new InkPoint(pts[j - 1].x + (pts[j].x - pts[j - 1].x) * t, pts[j - 1].y + (pts[j].y - pts[j - 1].y) * t));
                }
                seq.add(pts[pts.size - 1]);
            }
            if (seq.size == 0) return null;
            double x0, y0, x1, y1;
            bounds(seq, out x0, out y0, out x1, out y1);
            double scale = double.max(double.max(x1 - x0, y1 - y0), 1e-3);
            var res = new double[FLAT * 2];
            double cx = 0, cy = 0;
            for (int i = 0; i < FLAT; i++) {
                var p = seq[(int) ((double) i * (seq.size - 1) / (FLAT - 1))];
                res[i * 2] = p.x;
                res[i * 2 + 1] = p.y;
                cx += p.x;
                cy += p.y;
            }
            cx /= FLAT;
            cy /= FLAT;
            for (int i = 0; i < FLAT; i++) {
                res[i * 2] = (res[i * 2] - cx) / scale;
                res[i * 2 + 1] = (res[i * 2 + 1] - cy) / scale;
            }
            return res;
        }

        private static double flat_distance(double[] a, double[] b) {
            double sum = 0;
            for (int i = 0; i < FLAT; i++) sum += Math.hypot(a[i * 2] - b[i * 2], a[i * 2 + 1] - b[i * 2 + 1]);
            return sum / FLAT;
        }

        public string classify_letter(Gee.List<Stroke> strokes, double baseline, double xh) {
            if (letters.size > 0) {
                var flat = flat_of(strokes);
                if (flat == null) return "";
                string best = "";
                double min = double.MAX;
                foreach (var l in letters.values) {
                    foreach (var g in l) {
                        double d = flat_distance(flat, g.flat);
                        if (d < min) {
                            min = d;
                            best = g.ch;
                        }
                    }
                }
                return best;
            }
            var all = new Gee.ArrayList<InkPoint>();
            foreach (var st in strokes) foreach (var p in st.points) all.add(p);
            if (all.size == 0) return "";
            double x0, y0, x1, y1;
            bounds(all, out x0, out y0, out x1, out y1);
            var pts = resample_points(strokes, double.max(1e-3, double.max(x1 - x0, y1 - y0) / 40.0));
            double aspect;
            var cloud = cloud_of(pts, out aspect);
            if (cloud == null) return "";
            double top = (baseline - y0) / double.max(1e-3, xh);
            double bottom = (y1 - baseline) / double.max(1e-3, xh);
            string best = "";
            double min = double.MAX;
            ensure_glyphs();
            foreach (var g in glyphs) {
                double d = double.min(cloud_distance(cloud, g.cloud), cloud_distance(g.cloud, cloud));
                d += 0.8 * Math.fabs(Math.log(aspect / g.aspect));
                d += 0.6 * (Math.fabs(top - g.top) + Math.fabs(bottom - g.bottom));
                if (d < min) {
                    min = d;
                    best = g.ch;
                }
            }
            return best;
        }

        public HandwritingRecognizer() {
            var available = new Gee.HashSet<string>();
            var fm = Pango.CairoFontMap.get_default();
            Pango.FontFamily[] families;
            fm.list_families(out families);
            foreach (var f in families) available.add(f.get_name().casefold());
            foreach (string f in DEFAULT_FONTS) {
                if (available.contains(f.casefold())) fonts.add(f);
                if (fonts.size >= 2) break;
            }
            foreach (string f in FALLBACK_FONTS) {
                if (fonts.size >= 3) break;
                fonts.add(f);
            }
            string? path = find_letters();
            if (path != null) load_letters(path);
        }

        public void set_fonts(string[] list) {
            fonts.clear();
            foreach (string f in list) fonts.add(f);
            metrics.clear();
            cache.clear();
            shapes.clear();
            glyphs.clear();
        }

        public void add_words(Gee.Collection<string> words) {
            foreach (string w in words) {
                string c = clean_word(w);
                if (c.char_count() >= 1) note_words.add(c);
            }
        }

        public void add_text(string text) {
            var list = new Gee.ArrayList<string>();
            foreach (string w in text.split_set(" \t\n.,;:!?()[]{}\"'*_#<>|/")) list.add(w);
            add_words(list);
        }

        private static string clean_word(string w) {
            var sb = new StringBuilder();
            int i = 0;
            unichar c;
            while (w.get_next_char(ref i, out c)) {
                if (c.isalpha() || c.isdigit()) sb.append_unichar(c.tolower());
            }
            return sb.str;
        }

        public void load_dictionaries() {
            if (dict_loaded) return;
            dict_loaded = true;
            var names = new Gee.ArrayList<string>();
            foreach (string l in Intl.get_language_names()) {
                string base_name = l.split(".")[0].split("@")[0];
                if (base_name == "C" || base_name == "POSIX") continue;
                if (!names.contains(base_name)) names.add(base_name);
            }
            if (!names.contains("en_US")) names.add("en_US");
            var dirs = new Gee.ArrayList<string>();
            dirs.add(Environment.get_user_data_dir());
            foreach (string d in Environment.get_system_data_dirs()) dirs.add(d);
            foreach (string n in names) {
                foreach (string d in dirs) {
                    foreach (string sub in new string[] { "hunspell", "myspell/dicts", "myspell" }) {
                        string path = Path.build_filename(d, sub, n + ".dic");
                        if (FileUtils.test(path, FileTest.IS_REGULAR)) {
                            load_dic(path);
                            break;
                        }
                    }
                }
            }
        }

        private class HwAffix {
            public bool suffix;
            public string strip;
            public string add;
            public string[] cond;
            public bool[] negate;
        }

        private static bool affix_matches(HwAffix r, unichar[] word) {
            int n = r.cond.length;
            if (n > word.length) return false;
            for (int k = 0; k < n; k++) {
                unichar c = r.suffix ? word[word.length - n + k] : word[k];
                if (r.cond[k] == ".") continue;
                bool inside = r.cond[k].index_of_char(c) >= 0;
                if (r.negate[k]) inside = !inside;
                if (!inside) return false;
            }
            return true;
        }

        private static void parse_condition(HwAffix r, string cond) {
            string[] sets = {};
            bool[] neg = {};
            if (cond != ".") {
                int i = 0;
                unichar c;
                while (cond.get_next_char(ref i, out c)) {
                    if (c == '[') {
                        bool n = false;
                        var sb = new StringBuilder();
                        unichar d;
                        while (cond.get_next_char(ref i, out d) && d != ']') {
                            if (d == '^' && sb.len == 0 && !n) n = true;
                            else sb.append_unichar(d);
                        }
                        sets += sb.str;
                        neg += n;
                    } else {
                        sets += c == '.' ? "." : c.to_string();
                        neg += false;
                    }
                }
            }
            r.cond = sets;
            r.negate = neg;
        }

        private static string[] split_flags(string flags, string mode) {
            string[] out = {};
            if (mode == "long") {
                for (int i = 0; i + 1 < flags.length; i += 2) out += flags.substring(i, 2);
            } else if (mode == "num") {
                foreach (string f in flags.split(",")) if (f != "") out += f;
            } else {
                int i = 0;
                unichar c;
                while (flags.get_next_char(ref i, out c)) out += c.to_string();
            }
            return out;
        }

        private void add_dict_word(string w) {
            if (w.char_count() < 1 || w.char_count() > 24) return;
            int i = 0;
            unichar c;
            while (w.get_next_char(ref i, out c)) if (!c.isalpha() && c != '\'' && c != '-') return;
            string lw = w.down();
            if (dict_set.add(lw)) dict_words.add(lw);
        }

        public void add_dictionary_words(Gee.Collection<string> words) {
            foreach (string w in words) add_dict_word(w);
        }

        public void load_dic(string path) {
            string text;
            string aff_text = "";
            string aff = path.has_suffix(".dic") ? path.substring(0, path.length - 4) + ".aff" : "";
            try {
                if (!FileUtils.get_contents(path, out text)) return;
                if (aff != "" && FileUtils.test(aff, FileTest.IS_REGULAR)) FileUtils.get_contents(aff, out aff_text);
            } catch (FileError e) {
                return;
            }
            string charset = "UTF-8";
            string mode = "";
            var rules = new Gee.HashMap<string, Gee.ArrayList<HwAffix>>();
            foreach (string raw in aff_text.split("\n")) {
                string[] f = {};
                foreach (string t in raw.strip().split_set(" \t")) if (t != "") f += t;
                if (f.length >= 2 && f[0] == "SET") charset = f[1];
                if (f.length >= 2 && f[0] == "FLAG") mode = f[1];
                if (f.length >= 5 && (f[0] == "SFX" || f[0] == "PFX")) {
                    var r = new HwAffix();
                    r.suffix = f[0] == "SFX";
                    r.strip = f[2] == "0" ? "" : f[2];
                    string add = f[3].split("/")[0];
                    r.add = add == "0" ? "" : add;
                    parse_condition(r, f[4]);
                    if (!rules.has_key(f[1])) rules[f[1]] = new Gee.ArrayList<HwAffix>();
                    rules[f[1]].add(r);
                }
            }
            if (charset.down() != "utf-8") {
                try {
                    text = convert(text, -1, "UTF-8", charset);
                } catch (ConvertError e) {
                    return;
                }
            }
            if (!text.validate()) return;
            bool first = true;
            foreach (string line in text.split("\n")) {
                if (first) {
                    first = false;
                    continue;
                }
                string trimmed = line.strip();
                if (trimmed == "") continue;
                string entry = trimmed.split_set(" \t")[0];
                if (entry == null || entry == "") continue;
                int slash = entry.index_of_char('/');
                string w = slash >= 0 ? entry.substring(0, slash) : entry;
                string flags = slash >= 0 ? entry.substring(slash + 1) : "";
                add_dict_word(w);
                if (flags == "" || rules.size == 0) continue;
                unichar[] chars = {};
                int i = 0;
                unichar c;
                while (w.get_next_char(ref i, out c)) chars += c;
                foreach (string fl in split_flags(flags, mode)) {
                    var list = rules[fl];
                    if (list == null) continue;
                    foreach (var r in list) {
                        if (!affix_matches(r, chars)) continue;
                        if (r.suffix) {
                            if (r.strip != "" && !w.has_suffix(r.strip)) continue;
                            add_dict_word(w.substring(0, w.length - r.strip.length) + r.add);
                        } else {
                            if (r.strip != "" && !w.has_prefix(r.strip)) continue;
                            add_dict_word(r.add + w.substring(r.strip.length));
                        }
                    }
                }
            }
        }

        private HwFontMetrics font_metrics(string desc) {
            foreach (var m in metrics) if (m.desc == desc) return m;
            var m = new HwFontMetrics(desc);
            var surface = new Cairo.ImageSurface(Cairo.Format.A8, 8, 8);
            var cr = new Cairo.Context(surface);
            var layout = Pango.cairo_create_layout(cr);
            var fd = Pango.FontDescription.from_string(desc);
            fd.set_absolute_size(40 * Pango.SCALE);
            layout.set_font_description(fd);
            Pango.Rectangle ink, logical;
            double total = 0;
            int n = 0;
            int i = 0;
            unichar c;
            string letters = "abcdefghijklmnopqrstuvwxyz";
            while (letters.get_next_char(ref i, out c)) {
                layout.set_text(c.to_string(), -1);
                layout.get_pixel_extents(out ink, out logical);
                m.advance[c.to_string()] = logical.width;
                total += logical.width;
                n++;
            }
            m.fallback_advance = n > 0 ? total / n : 20;
            layout.set_text("x", -1);
            layout.get_pixel_extents(out ink, out logical);
            int baseline = layout.get_baseline() / Pango.SCALE;
            m.xheight = double.max(1, baseline - ink.y);
            layout.set_text("h", -1);
            layout.get_pixel_extents(out ink, out logical);
            m.ascent = double.max(m.xheight, baseline - ink.y);
            layout.set_text("p", -1);
            layout.get_pixel_extents(out ink, out logical);
            m.descent = double.max(0, ink.y + ink.height - baseline);
            metrics.add(m);
            var ratios = new double[CALIBRATION.length];
            for (int k = 0; k < CALIBRATION.length; k++) {
                var t = template(CALIBRATION[k], desc);
                ratios[k] = t != null ? t.aspect / double.max(1e-3, estimate_aspect(CALIBRATION[k], m)) : 1.0;
            }
            sort_doubles(ratios);
            m.aspect_scale = ratios[ratios.length / 2];
            return m;
        }

        private static bool has_any(string word, string set) {
            int i = 0;
            unichar c;
            while (word.get_next_char(ref i, out c)) if (set.index_of_char(c) >= 0) return true;
            return false;
        }

        private double estimate_aspect(string word, HwFontMetrics m) {
            double w = 0;
            int i = 0;
            unichar c;
            while (word.get_next_char(ref i, out c)) {
                var a = m.advance[c.to_string()];
                w += a != null ? a : m.fallback_advance;
            }
            double h = m.xheight;
            if (has_any(word, ASC) || has_any(word, "ij")) h = m.ascent;
            if (has_any(word, DESC)) h += m.descent;
            return m.aspect_scale * w / double.max(1, h);
        }

        public static void thin(bool[] g, int w, int h) {
            bool changed = true;
            var remove = new Gee.ArrayList<int>();
            while (changed) {
                changed = false;
                for (int pass = 0; pass < 2; pass++) {
                    remove.clear();
                    for (int y = 1; y < h - 1; y++) {
                        for (int x = 1; x < w - 1; x++) {
                            if (!g[y * w + x]) continue;
                            bool p2 = g[(y - 1) * w + x], p3 = g[(y - 1) * w + x + 1], p4 = g[y * w + x + 1], p5 = g[(y + 1) * w + x + 1];
                            bool p6 = g[(y + 1) * w + x], p7 = g[(y + 1) * w + x - 1], p8 = g[y * w + x - 1], p9 = g[(y - 1) * w + x - 1];
                            int b = (int) p2 + (int) p3 + (int) p4 + (int) p5 + (int) p6 + (int) p7 + (int) p8 + (int) p9;
                            if (b < 2 || b > 6) continue;
                            bool[] seq = { p2, p3, p4, p5, p6, p7, p8, p9, p2 };
                            int a = 0;
                            for (int i = 0; i < 8; i++) if (!seq[i] && seq[i + 1]) a++;
                            if (a != 1) continue;
                            if (pass == 0) {
                                if (p2 && p4 && p6) continue;
                                if (p4 && p6 && p8) continue;
                            } else {
                                if (p2 && p4 && p8) continue;
                                if (p2 && p6 && p8) continue;
                            }
                            remove.add(y * w + x);
                        }
                    }
                    foreach (int i in remove) g[i] = false;
                    if (remove.size > 0) changed = true;
                }
            }
        }

        private static int free_neighbours(bool[] g, bool[] used, int w, int h, int x, int y) {
            int n = 0;
            for (int dy = -1; dy <= 1; dy++) {
                for (int dx = -1; dx <= 1; dx++) {
                    if (dx == 0 && dy == 0) continue;
                    int nx = x + dx;
                    int ny = y + dy;
                    if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                    if (g[ny * w + nx] && !used[ny * w + nx]) n++;
                }
            }
            return n;
        }

        public static Gee.ArrayList<Stroke> trace(bool[] g, int w, int h, double ox, double oy, double scale) {
            var strokes = new Gee.ArrayList<Stroke>();
            var used = new bool[w * h];
            int[] dxs = { 1, 0, -1, 0, 1, -1, 1, -1 };
            int[] dys = { 0, 1, 0, -1, 1, 1, -1, -1 };
            while (true) {
                int start = -1;
                for (int i = 0; i < w * h && start < 0; i++) {
                    if (g[i] && !used[i] && free_neighbours(g, used, w, h, i % w, i / w) <= 1) start = i;
                }
                for (int i = 0; i < w * h && start < 0; i++) if (g[i] && !used[i]) start = i;
                if (start < 0) break;
                var s = new Stroke();
                int x = start % w;
                int y = start / w;
                while (true) {
                    used[y * w + x] = true;
                    s.points.add(new InkPoint(ox + x * scale, oy + y * scale));
                    int bx = -1, by = -1;
                    for (int k = 0; k < 8 && bx < 0; k++) {
                        int nx = x + dxs[k];
                        int ny = y + dys[k];
                        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                        if (g[ny * w + nx] && !used[ny * w + nx]) {
                            bx = nx;
                            by = ny;
                        }
                    }
                    if (bx < 0) break;
                    x = bx;
                    y = by;
                }
                if (s.points.size >= 2) strokes.add(s);
            }
            return strokes;
        }

        private class Bitmap {
            public bool[] grid;
            public int w;
            public int h;
            public int baseline;
        }

        private static Bitmap? render_text(string text, string desc, double size) {
            var probe = new Cairo.ImageSurface(Cairo.Format.A8, 8, 8);
            var pcr = new Cairo.Context(probe);
            var layout = Pango.cairo_create_layout(pcr);
            var fd = Pango.FontDescription.from_string(desc);
            fd.set_absolute_size((int) (size * Pango.SCALE));
            layout.set_font_description(fd);
            layout.set_text(text, -1);
            Pango.Rectangle ink, logical;
            layout.get_pixel_extents(out ink, out logical);
            if (ink.width <= 0 || ink.height <= 0) return null;
            int w = ink.width + 4;
            int h = ink.height + 4;
            var surface = new Cairo.ImageSurface(Cairo.Format.A8, w, h);
            var cr = new Cairo.Context(surface);
            var l2 = Pango.cairo_create_layout(cr);
            l2.set_font_description(fd);
            l2.set_text(text, -1);
            cr.move_to(2 - ink.x, 2 - ink.y);
            Pango.cairo_show_layout(cr, l2);
            surface.flush();
            unowned uint8[] data = surface.get_data();
            int stride = surface.get_stride();
            var bm = new Bitmap();
            bm.w = w;
            bm.h = h;
            bm.grid = new bool[w * h];
            bm.baseline = 2 - ink.y + layout.get_baseline() / Pango.SCALE;
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) bm.grid[y * w + x] = data[y * stride + x] > 110;
            return bm;
        }

        public static Gee.List<InkPoint> resample_points(Gee.List<Stroke> strokes, double spacing) {
            var pts = new Gee.ArrayList<InkPoint>();
            foreach (var s in strokes) {
                if (s.points.size == 0) continue;
                var prev = s.points[0];
                pts.add(new InkPoint(prev.x, prev.y));
                double acc = 0;
                for (int i = 1; i < s.points.size; i++) {
                    var cur = s.points[i];
                    double d = Math.hypot(cur.x - prev.x, cur.y - prev.y);
                    double t = spacing - acc;
                    while (t <= d) {
                        double k = t / d;
                        pts.add(new InkPoint(prev.x + (cur.x - prev.x) * k, prev.y + (cur.y - prev.y) * k));
                        t += spacing;
                    }
                    acc = d - (t - spacing);
                    prev = cur;
                }
            }
            return pts;
        }

        private static void bounds(Gee.List<InkPoint> pts, out double x0, out double y0, out double x1, out double y1) {
            x0 = double.MAX;
            y0 = double.MAX;
            x1 = -double.MAX;
            y1 = -double.MAX;
            foreach (var p in pts) {
                x0 = double.min(x0, p.x);
                y0 = double.min(y0, p.y);
                x1 = double.max(x1, p.x);
                y1 = double.max(y1, p.y);
            }
        }

        private static double find_slant(Gee.List<InkPoint> pts) {
            double x0, y0, x1, y1;
            bounds(pts, out x0, out y0, out x1, out y1);
            int off = (int) Math.floor(x0) - H - 2;
            int size = (int) Math.ceil(x1) - off + H + 4;
            var bins = new int[size];
            double best = -1;
            double best_s = 0;
            for (int k = -10; k <= 10; k++) {
                double s = k * 0.08;
                for (int i = 0; i < size; i++) bins[i] = 0;
                foreach (var p in pts) bins[((int) Math.floor(p.x - s * (H - p.y)) - off).clamp(0, size - 1)]++;
                double score = 0;
                foreach (int v in bins) score += (double) v * v;
                if (score > best) {
                    best = score;
                    best_s = s;
                }
            }
            return best_s;
        }

        public static HwFeatures? features_of_points(Gee.List<InkPoint> raw) {
            if (raw.size < 2) return null;
            double x0, y0, x1, y1;
            bounds(raw, out x0, out y0, out x1, out y1);
            double bh = double.max(1e-3, y1 - y0);
            double k = (H - 1) / bh;
            if ((x1 - x0) * k > H * 40) k = H * 40 / double.max(1e-3, x1 - x0);
            var pts = new Gee.ArrayList<InkPoint>();
            foreach (var p in raw) pts.add(new InkPoint((p.x - x0) * k, (p.y - y0) * k));
            double shear = find_slant(pts);
            foreach (var p in pts) p.x = p.x - shear * (H - p.y);
            bounds(pts, out x0, out y0, out x1, out y1);
            double cs = 1.0;
            int span = int.max(1, (int) Math.ceil((x1 - x0 + 1) / COL));
            var ys = new Gee.ArrayList<Gee.ArrayList<double?>>();
            var dirs = new Gee.ArrayList<double?>();
            for (int c = 0; c < span; c++) ys.add(new Gee.ArrayList<double?>());
            var orient = new double[span * 4];
            for (int i = 0; i < pts.size; i++) {
                var p = pts[i];
                int c = ((int) Math.floor((p.x - x0) / COL)).clamp(0, span - 1);
                ys[c].add(p.y);
                InkPoint? q = i + 1 < pts.size ? pts[i + 1] : null;
                if (q == null || Math.hypot(q.x - p.x, q.y - p.y) > 3 * cs) continue;
                double ang = Math.atan2(q.y - p.y, q.x - p.x);
                if (ang < 0) ang += Math.PI;
                int bin = ((int) Math.round(ang / (Math.PI / 4))) % 4;
                orient[c * 4 + bin] += 1;
            }
            var filled = new Gee.ArrayList<int>();
            for (int c = 0; c < span; c++) if (ys[c].size > 0) filled.add(c);
            int cols = int.max(1, filled.size);
            var f = new HwFeatures(cols);
            f.aspect = cols * COL / H;
            var ups = new double[cols];
            var lows = new double[cols];
            for (int n = 0; n < filled.size; n++) {
                int c = filled[n];
                var col = ys[c];
                col.sort((a, b) => a < b ? -1 : (a > b ? 1 : 0));
                double up = col[0] / H;
                double low = col[col.size - 1] / H;
                double sum = 0;
                foreach (var y in col) sum += y;
                double trans = 1;
                for (int i = 1; i < col.size; i++) if (col[i] - col[i - 1] > 2.5) trans++;
                int o = n * F;
                f.data[o] = up;
                f.data[o + 1] = low;
                f.data[o + 2] = sum / col.size / H;
                f.data[o + 3] = double.min(trans, 4) / 4.0;
                foreach (var y in col) {
                    int z = ((int) Math.floor(y / H * ZONES)).clamp(0, ZONES - 1);
                    f.data[o + 4 + z] = 1;
                }
                double ot = orient[c * 4] + orient[c * 4 + 1] + orient[c * 4 + 2] + orient[c * 4 + 3];
                for (int d = 0; d < 4; d++) f.data[o + 4 + ZONES + d] = ot > 0 ? orient[c * 4 + d] / ot : 0.25;
                ups[n] = up;
                lows[n] = low;
            }
            sort_doubles(ups);
            sort_doubles(lows);
            f.ascender = ups[cols / 2] > 0.22;
            f.descender = lows[cols / 2] < 0.78;
            return f;
        }

        private static void sort_doubles(double[] v) {
            for (int i = 1; i < v.length; i++) {
                double x = v[i];
                int j = i - 1;
                while (j >= 0 && v[j] > x) {
                    v[j + 1] = v[j];
                    j--;
                }
                v[j + 1] = x;
            }
        }

        public static HwFeatures? features_of_strokes(Gee.List<Stroke> strokes) {
            var raw = new Gee.ArrayList<InkPoint>();
            foreach (var s in strokes) foreach (var p in s.points) raw.add(p);
            if (raw.size == 0) return null;
            double x0, y0, x1, y1;
            bounds(raw, out x0, out y0, out x1, out y1);
            double spacing = double.max(1e-3, (y1 - y0) / (H - 1));
            return features_of_points(resample_points(strokes, spacing));
        }

        private HwFeatures? template(string word, string font, bool printed = false) {
            string key = font + (printed ? "\np\n" : "\nc\n") + word;
            if (cache.has_key(key)) return cache[key];
            HwFeatures? f = null;
            if (font.has_prefix("uji:")) {
                var strokes = real_word(word, int.parse(font.substring(4)), printed);
                if (strokes != null) f = features_of_strokes(strokes);
            } else {
                f = features_of_strokes(synthesize(word, font, 40, 0, 0, !printed, 1));
            }
            cache[key] = f;
            return f;
        }

        public static double dtw(HwFeatures a, HwFeatures b) {
            int n = a.cols;
            int m = b.cols;
            int band = int.max((n - m).abs(), (int) (int.max(n, m) * 0.3)) + 2;
            var prev = new double[m + 1];
            var cur = new double[m + 1];
            for (int j = 0; j <= m; j++) prev[j] = double.MAX;
            prev[0] = 0;
            for (int i = 1; i <= n; i++) {
                for (int j = 0; j <= m; j++) cur[j] = double.MAX;
                int center = (int) ((double) i * m / n);
                int lo = int.max(1, center - band);
                int hi = int.min(m, center + band);
                for (int j = lo; j <= hi; j++) {
                    double d = 0;
                    int ia = (i - 1) * F;
                    int jb = (j - 1) * F;
                    for (int q = 0; q < F; q++) {
                        double e = a.data[ia + q] - b.data[jb + q];
                        d += WEIGHTS[q] * e * e;
                    }
                    d = Math.sqrt(d);
                    double best = prev[j - 1];
                    if (prev[j] != double.MAX && prev[j] + step_penalty < best) best = prev[j] + step_penalty;
                    if (cur[j - 1] != double.MAX && cur[j - 1] + step_penalty < best) best = cur[j - 1] + step_penalty;
                    if (best == double.MAX) continue;
                    cur[j] = best + d;
                }
                var t = prev;
                prev = cur;
                cur = t;
            }
            if (prev[m] == double.MAX) return double.MAX;
            return prev[m] / (n + m);
        }

        private double shape_penalty(HwFeatures ink, string w) {
            if (has_any(w, "f")) return 0;
            double penalty = 0;
            bool asc = has_any(w, ASC) || w.get_char(0).isupper();
            if (asc != ink.ascender) penalty += shape_penalty_weight;
            if (has_any(w, DESC) != ink.descender) penalty += shape_penalty_weight;
            return penalty;
        }

        private static Gee.ArrayList<double?> ink_blobs(HwFeatures ink, bool upper) {
            var blobs = new Gee.ArrayList<double?>();
            if (upper ? !ink.ascender : !ink.descender) return blobs;
            int start = -1;
            for (int c = 0; c <= ink.cols; c++) {
                bool on = c < ink.cols && (upper ? ink.data[c * F] < 0.15 : ink.data[c * F + 1] > 0.85);
                if (on && start < 0) start = c;
                if (!on && start >= 0) {
                    blobs.add((start + c) / 2.0 / ink.cols);
                    start = -1;
                }
            }
            return blobs;
        }

        private Gee.ArrayList<double?> word_blobs(string word, HwFontMetrics m, bool upper) {
            var blobs = new Gee.ArrayList<double?>();
            double total = 0;
            int i = 0;
            unichar c;
            while (word.get_next_char(ref i, out c)) {
                var a = m.advance[c.to_string()];
                total += a != null ? a : m.fallback_advance;
            }
            double x = 0;
            double run = 0;
            double sum = 0;
            i = 0;
            while (word.get_next_char(ref i, out c)) {
                var a = m.advance[c.to_string()];
                double adv = a != null ? a : m.fallback_advance;
                bool on = upper ? (ASC.index_of_char(c) >= 0 || c.isupper()) : DESC.index_of_char(c) >= 0;
                if (on) {
                    run++;
                    sum += (x + adv / 2) / double.max(1, total);
                } else if (run > 0) {
                    blobs.add(sum / run);
                    run = 0;
                    sum = 0;
                }
                x += adv;
            }
            if (run > 0) blobs.add(sum / run);
            return blobs;
        }

        private static Gee.ArrayList<double?> merge_blobs(Gee.List<double?> list) {
            var result = new Gee.ArrayList<double?>();
            double sum = 0;
            int n = 0;
            foreach (var v in list) {
                if (n > 0 && v - sum / n > BLOB_MERGE) {
                    result.add(sum / n);
                    sum = 0;
                    n = 0;
                }
                sum += v;
                n++;
            }
            if (n > 0) result.add(sum / n);
            return result;
        }

        private HwShape word_shape(string w, HwFontMetrics m) {
            string key = m.desc + "\n" + w;
            var cached = shapes[key];
            if (cached != null) return cached;
            var shape = new HwShape();
            shape.aspect = estimate_aspect(w, m);
            shape.asc = merge_blobs(word_blobs(w, m, true));
            shape.desc = merge_blobs(word_blobs(w, m, false));
            shapes[key] = shape;
            return shape;
        }

        private static double blob_distance(Gee.List<double?> a, Gee.List<double?> b) {
            double d = 0.25 * (a.size - b.size).abs();
            int n = int.min(a.size, b.size);
            if (a.size == b.size) {
                for (int k = 0; k < n; k++) d += Math.fabs(a[k] - b[k]);
            } else {
                d += 0.1 * n;
            }
            return d;
        }

        private static string capitalized(string w) {
            unichar c = w.get_char(0);
            return c.toupper().to_string() + w.substring(c.to_string().length);
        }

        private double word_score(HwFeatures ink, HwCandidate cand, Gee.List<string> use_fonts, bool both) {
            double best = double.MAX;
            string shown = cand.word;
            var forms = new Gee.ArrayList<string>();
            forms.add(cand.word);
            string cap = capitalized(cand.word);
            if (cap != cand.word) forms.add(cap);
            foreach (string form in forms) {
                double penalty = shape_penalty(ink, form) + (form != cand.word ? capital_penalty : 0);
                foreach (string font in use_fonts) {
                    foreach (bool printed in both ? new bool[] { false, true } : new bool[] { ink.printed }) {
                        var t = template(form, font, printed);
                        if (t == null) continue;
                        double ar = Math.fabs(Math.log(ink.aspect / double.max(1e-3, t.aspect)));
                        double d = dtw(ink, t) + aspect_weight * ar + penalty;
                        if (d < best) {
                            best = d;
                            shown = form;
                        }
                    }
                }
            }
            cand.text = shown;
            return best;
        }

        private Gee.List<HwCandidate> rank(HwFeatures ink, Gee.Collection<string> words, int top, int limit) {
            foreach (string font in fonts) font_metrics(font);
            var metric = font_metrics(fonts[0]);
            var ink_asc = merge_blobs(ink_blobs(ink, true));
            var ink_desc = merge_blobs(ink_blobs(ink, false));
            var pre = new Gee.ArrayList<HwCandidate>();
            foreach (string w in words) {
                if (w == "") continue;
                var shape = word_shape(w, metric);
                double gap = Math.fabs(Math.log(shape.aspect / double.max(1e-3, ink.aspect)));
                if (gap > 0.6 && limit < words.size) continue;
                double fit = limit < words.size ? blob_distance(ink_asc, shape.asc) + blob_distance(ink_desc, shape.desc) : 0;
                pre.add(new HwCandidate(w, 0.5 * gap + fit));
            }
            pre.sort((a, b) => a.score < b.score ? -1 : (a.score > b.score ? 1 : 0));
            while (pre.size > limit) pre.remove_at(pre.size - 1);
            var first = new Gee.ArrayList<string>();
            first.add(fonts[0]);
            bool small = limit >= words.size;
            foreach (var c in pre) c.score = word_score(ink, c, pre.size > FULL_RANK && !small ? first : sources(fonts), small);
            pre.sort((a, b) => a.score < b.score ? -1 : (a.score > b.score ? 1 : 0));
            if (pre.size > FULL_RANK && limit < words.size) {
                while (pre.size > FULL_RANK) pre.remove_at(pre.size - 1);
                foreach (var c in pre) c.score = word_score(ink, c, sources(fonts), small);
                pre.sort((a, b) => a.score < b.score ? -1 : (a.score > b.score ? 1 : 0));
            }
            while (pre.size > top) pre.remove_at(pre.size - 1);
            return pre;
        }

        public Gee.List<HwCandidate> recognize_word_candidates(Gee.List<Stroke> strokes, int top = 5, bool printed = false, bool dictionary = true) {
            var result = new Gee.ArrayList<HwCandidate>();
            var ink = features_of_strokes(strokes);
            if (ink == null) return result;
            ink.printed = printed;
            HwCandidate? learned = null;
            foreach (var s in samples) {
                double d = dtw(ink, s.features);
                double ar = Math.fabs(Math.log(ink.aspect / double.max(1e-3, s.features.aspect)));
                d = (d + aspect_weight * ar) * sample_prior;
                if (learned == null || d < learned.score) learned = new HwCandidate(s.text, d);
            }
            if (learned != null && learned.score < SAMPLE_OK) {
                result.add(learned);
                return result;
            }
            ensure_net();
            if (use_net && net != null) {
                foreach (var c in net_candidates(strokes, top, dictionary)) result.add(c);
                return result;
            }
            if (note_words.size > 0) {
                foreach (var c in rank(ink, note_words, top, note_words.size)) {
                    c.score *= note_prior;
                    result.add(c);
                }
            }
            if (dictionary && use_dictionary && (result.size == 0 || result[0].score > NOTE_OK)) {
                load_dictionaries();
                foreach (var c in rank(ink, dict_words, top, max_candidates)) if (!note_words.contains(c.word)) result.add(c);
            }
            if (learned != null) result.add(learned);
            result.sort((a, b) => a.score < b.score ? -1 : (a.score > b.score ? 1 : 0));
            while (result.size > top) result.remove_at(result.size - 1);
            return result;
        }

        private class Cluster {
            public Gee.ArrayList<Stroke> strokes = new Gee.ArrayList<Stroke>();
            public double x0 = double.MAX;
            public double y0 = double.MAX;
            public double x1 = -double.MAX;
            public double y1 = -double.MAX;

            public void add(Stroke s) {
                strokes.add(s);
                foreach (var p in s.points) {
                    x0 = double.min(x0, p.x);
                    y0 = double.min(y0, p.y);
                    x1 = double.max(x1, p.x);
                    y1 = double.max(y1, p.y);
                }
            }

            public void merge(Cluster o) {
                foreach (var s in o.strokes) add(s);
            }

            public double width {
                get { return x1 - x0; }
            }

            public double height {
                get { return y1 - y0; }
            }
        }

        private static Gee.ArrayList<Cluster> lines_of(Gee.List<Stroke> strokes) {
            var items = new Gee.ArrayList<Cluster>();
            foreach (var s in strokes) {
                if (s.points.size == 0 || s.tool == "highlighter") continue;
                var c = new Cluster();
                c.add(s);
                items.add(c);
            }
            items.sort((a, b) => a.height > b.height ? -1 : (a.height < b.height ? 1 : 0));
            var lines = new Gee.ArrayList<Cluster>();
            foreach (var it in items) {
                Cluster? target = null;
                double best = 0;
                foreach (var l in lines) {
                    double ov = double.min(l.y1, it.y1) - double.max(l.y0, it.y0);
                    double frac = ov / double.max(1e-3, double.min(l.height, double.max(it.height, 1)));
                    double cy = (it.y0 + it.y1) / 2;
                    if (it.height < l.height * 0.25 && cy > l.y0 - l.height * 0.6 && cy < l.y1 + l.height * 0.2) frac = double.max(frac, 0.6);
                    if (cy > l.y0 && cy < l.y1) frac = double.max(frac, 0.5);
                    if (ov > 0 && it.height < l.height * 0.7) frac = double.max(frac, 0.31 + ov / double.max(1, it.height) * 0.1);
                    if (frac > 0.3 && frac > best) {
                        best = frac;
                        target = l;
                    }
                }
                if (target != null) target.merge(it);
                else lines.add(it);
            }
            lines.sort((a, b) => a.y0 < b.y0 ? -1 : (a.y0 > b.y0 ? 1 : 0));
            return lines;
        }

        private static bool touches(Cluster a, Cluster b, double tol) {
            if (b.x0 > a.x1 + tol) return false;
            foreach (var s in b.strokes) {
                var ends = new InkPoint[] { s.points[0], s.points[s.points.size - 1] };
                foreach (var e in ends) {
                    foreach (var t in a.strokes) foreach (var p in t.points) if (Math.fabs(p.x - e.x) <= tol && Math.fabs(p.y - e.y) <= tol) return true;
                }
            }
            foreach (var t in a.strokes) {
                var ends = new InkPoint[] { t.points[0], t.points[t.points.size - 1] };
                foreach (var e in ends) {
                    foreach (var s in b.strokes) foreach (var p in s.points) if (Math.fabs(p.x - e.x) <= tol && Math.fabs(p.y - e.y) <= tol) return true;
                }
            }
            return false;
        }

        private static Gee.ArrayList<Cluster> columns_of(Cluster line) {
            var items = new Gee.ArrayList<Cluster>();
            foreach (var s in line.strokes) {
                var c = new Cluster();
                c.add(s);
                items.add(c);
            }
            items.sort((a, b) => a.x0 < b.x0 ? -1 : (a.x0 > b.x0 ? 1 : 0));
            var merged = new Gee.ArrayList<Cluster>();
            foreach (var it in items) {
                if (merged.size > 0) {
                    var last = merged[merged.size - 1];
                    double ov = double.min(last.x1, it.x1) - double.max(last.x0, it.x0);
                    double narrow = double.max(1, double.min(last.width, it.width));
                    if (ov / narrow > 0.35 || touches(last, it, line.height * 0.05) || (it.width < line.height * 0.15 && it.height < line.height * 0.2 && it.x0 < last.x1 + line.height * 0.1)) {
                        last.merge(it);
                        continue;
                    }
                }
                merged.add(it);
            }
            return merged;
        }

        private class Segment {
            public Gee.ArrayList<Cluster> parts = new Gee.ArrayList<Cluster>();
            public HwCandidate? best;
        }

        private Gee.ArrayList<Segment> segment_line(Cluster line) {
            var cols = columns_of(line);
            double h = double.max(1, line.height);
            var units = new Gee.ArrayList<Gee.ArrayList<Cluster>>();
            var gaps = new Gee.ArrayList<double?>();
            double reach = -double.MAX;
            foreach (var c in cols) {
                double gap = c.x0 - reach;
                if (units.size == 0 || gap > word_gap * h) {
                    if (units.size > 0) gaps.add(gap);
                    units.add(new Gee.ArrayList<Cluster>());
                }
                units[units.size - 1].add(c);
                reach = double.max(reach, c.x1);
            }
            int n = units.size;
            double threshold = word_gap * h;
            var widths = new double[cols.size];
            for (int i = 0; i < cols.size; i++) widths[i] = cols[i].width;
            var sorted_gaps = new double[gaps.size];
            for (int i = 0; i < gaps.size; i++) sorted_gaps[i] = gaps[i];
            sort_doubles(widths);
            sort_doubles(sorted_gaps);
            if (widths.length > 2 && sorted_gaps.length > 1 && widths[widths.length / 2] < h * 0.8) {
                threshold = double.max(h * 0.45, sorted_gaps[sorted_gaps.length / 2] * 2.0);
            }
            var cost = new double[n + 1];
            var from = new int[n + 1];
            var chosen = new HwCandidate?[n + 1];
            for (int i = 1; i <= n; i++) cost[i] = double.MAX;
            for (int i = 1; i <= n; i++) {
                for (int j = i - 1; j >= 0 && i - j <= MAX_SEGMENT; j--) {
                    if (j < i - 1 && gaps[j] > HARD_GAP * h) break;
                    if (cost[j] == double.MAX) continue;
                    var ws = new Gee.ArrayList<Stroke>();
                    int pieces = 0;
                    double x0 = double.MAX, x1 = -double.MAX;
                    for (int k = j; k < i; k++) {
                        foreach (var c in units[k]) {
                            ws.add_all(c.strokes);
                            pieces++;
                            x0 = double.min(x0, c.x0);
                            x1 = double.max(x1, c.x1);
                        }
                    }
                    var cands = recognize_word_candidates(ws, 3, pieces >= 3, false);
                    HwCandidate? best = cands.size > 0 ? cands[0] : null;
                    double score = best != null ? best.score : UNKNOWN_SCORE;
                    double c = cost[j] + score * ((x1 - x0) / h + 0.5) + word_cost;
                    for (int k = j; k < i - 1; k++) c += gap_weight * double.max(0, gaps[k] - threshold) / h + merge_cost;
                    if (j > 0) c += gap_weight * double.max(0, threshold - gaps[j - 1]) / h;
                    if (c < cost[i]) {
                        cost[i] = c;
                        from[i] = j;
                        chosen[i] = best;
                    }
                }
            }
            var result = new Gee.ArrayList<Segment>();
            int at = n;
            while (at > 0) {
                var seg = new Segment();
                for (int k = from[at]; k < at; k++) seg.parts.add_all(units[k]);
                seg.best = chosen[at];
                if (use_dictionary && (seg.best == null || seg.best.score > NOTE_OK)) {
                    var ws = new Gee.ArrayList<Stroke>();
                    foreach (var c in seg.parts) ws.add_all(c.strokes);
                    var cands = recognize_word_candidates(ws, 3, seg.parts.size >= 3);
                    if (cands.size > 0) seg.best = cands[0];
                }
                result.insert(0, seg);
                at = from[at];
            }
            return result;
        }

        private void ensure_glyphs() {
            if (glyphs.size > 0) return;
            foreach (string font in fonts) {
                var m = font_metrics(font);
                int i = 0;
                unichar c;
                while (CHARS.get_next_char(ref i, out c)) {
                    var bm = render_text(c.to_string(), font, 40);
                    if (bm == null) continue;
                    thin(bm.grid, bm.w, bm.h);
                    var pts = new Gee.ArrayList<InkPoint>();
                    for (int y = 0; y < bm.h; y++) for (int x = 0; x < bm.w; x++) if (bm.grid[y * bm.w + x]) pts.add(new InkPoint(x, y));
                    var g = new HwGlyph();
                    g.ch = c.to_string();
                    g.cloud = cloud_of(pts, out g.aspect);
                    if (g.cloud == null) continue;
                    double x0, y0, x1, y1;
                    bounds(pts, out x0, out y0, out x1, out y1);
                    g.top = (bm.baseline - y0) / m.xheight;
                    g.bottom = (y1 - bm.baseline) / m.xheight;
                    glyphs.add(g);
                }
            }
        }

        private static double[]? cloud_of(Gee.List<InkPoint> pts, out double aspect) {
            aspect = 1;
            if (pts.size == 0) return null;
            double x0, y0, x1, y1;
            bounds(pts, out x0, out y0, out x1, out y1);
            double w = x1 - x0;
            double h = y1 - y0;
            aspect = (h + 1) / (w + 1);
            double scale = double.max(double.max(w, h), 1e-3);
            double cx = 0, cy = 0;
            foreach (var p in pts) {
                cx += p.x;
                cy += p.y;
            }
            cx /= pts.size;
            cy /= pts.size;
            var res = new double[CLOUD * 2];
            for (int i = 0; i < CLOUD; i++) {
                var p = pts[(int) ((double) i * pts.size / CLOUD)];
                res[i * 2] = (p.x - cx) / scale;
                res[i * 2 + 1] = (p.y - cy) / scale;
            }
            return res;
        }

        private static double cloud_distance(double[] a, double[] b) {
            var matched = new bool[CLOUD];
            double sum = 0;
            for (int i = 0; i < CLOUD; i++) {
                int best = -1;
                double min = double.MAX;
                for (int j = 0; j < CLOUD; j++) {
                    if (matched[j]) continue;
                    double d = Math.hypot(a[i * 2] - b[j * 2], a[i * 2 + 1] - b[j * 2 + 1]);
                    if (d < min) {
                        min = d;
                        best = j;
                    }
                }
                matched[best] = true;
                sum += (1.0 - (double) i / CLOUD) * min;
            }
            return sum;
        }

        private string classify_char(Cluster c, double baseline, double xh) {
            return classify_letter(c.strokes, baseline, xh);
        }

        private static void core_band(Cluster line, out double baseline, out double xh) {
            var hist = new Gee.HashMap<int, int>();
            double bin = double.max(1, line.height / 40.0);
            int max = 0;
            foreach (var p in resample_points(line.strokes, bin)) {
                int b = (int) ((p.y - line.y0) / bin);
                int v = (hist.has_key(b) ? hist[b] : 0) + 1;
                hist[b] = v;
                max = int.max(max, v);
            }
            int top = int.MAX, bottom = -1;
            foreach (var e in hist.entries) {
                if (e.value >= max * 0.35) {
                    top = int.min(top, e.key);
                    bottom = int.max(bottom, e.key);
                }
            }
            if (bottom < 0) {
                baseline = line.y1;
                xh = line.height;
                return;
            }
            baseline = line.y0 + (bottom + 1) * bin;
            xh = double.max(bin, (bottom + 1 - top) * bin);
        }

        private void ensure_net() {
            if (net_tried) return;
            net_tried = true;
            string? path = HwNet.find_model();
            if (path != null) net = HwNet.load(path);
        }

        public bool has_net() {
            ensure_net();
            return net != null;
        }

        public string net_source() {
            ensure_net();
            return net != null ? net.source + " (" + net.license + ")" : "";
        }

        private static string upper_first(string w) {
            if (w == "") return w;
            unichar c = w.get_char(0);
            return c.toupper().to_string() + w.substring(w.index_of_nth_char(1));
        }

        private static int upper_count(string w) {
            int n = 0;
            int i = 0;
            unichar c;
            while (w.get_next_char(ref i, out c)) if (c.isupper()) n++;
            return n;
        }

        private static float viterbi(float[] lp, int T, int classes, int[] labels) {
            int L = labels.length;
            int S = 2 * L + 1;
            var alpha = new float[S];
            var next = new float[S];
            for (int s = 0; s < S; s++) alpha[s] = -float.INFINITY;
            alpha[0] = lp[0];
            if (S > 1) alpha[1] = lp[labels[0]];
            for (int t = 1; t < T; t++) {
                int lo = int.max(0, S - 2 * (T - t));
                int hi = int.min(S, 2 * t + 2);
                for (int s = 0; s < S; s++) {
                    if (s < lo || s >= hi) {
                        next[s] = -float.INFINITY;
                        continue;
                    }
                    int lab = (s & 1) == 0 ? 0 : labels[s >> 1];
                    float v = alpha[s];
                    if (s > 0 && alpha[s - 1] > v) v = alpha[s - 1];
                    if (s > 1 && lab != 0 && labels[s >> 1] != labels[(s >> 1) - 1] && alpha[s - 2] > v) v = alpha[s - 2];
                    next[s] = v + lp[t * classes + lab];
                }
                var tmp = alpha;
                alpha = next;
                next = tmp;
            }
            return -float.max(alpha[S - 1], S > 1 ? alpha[S - 2] : -float.INFINITY);
        }

        private Gee.List<HwCandidate> net_candidates(Gee.List<Stroke> strokes, int top, bool dictionary) {
            var result = new Gee.ArrayList<HwCandidate>();
            int width;
            double left, scale;
            var img = HwNet.render_scaled(strokes, out width, out left, out scale);
            if (img == null) return result;
            int T;
            var lp = net.forward(img, width, out T);
            if (lp == null) return result;
            int C = net.class_count;
            string greedy = net.greedy(lp, T);
            int glen = greedy.char_count();
            var words = new Gee.ArrayList<string>();
            words.add_all(note_words);
            foreach (var s in samples) if (!note_words.contains(s.text)) words.add(s.text);
            var pre = new Gee.ArrayList<HwCandidate>();
            bool caps = upper_count(greedy) >= 2 && upper_count(greedy) * 2 >= glen;
            var seen = new Gee.HashSet<string>();
            foreach (string w in words) {
                string[] forms = caps ? new string[] { w, upper_first(w), w.up() } : new string[] { w, upper_first(w) };
                for (int f = 0; f < forms.length; f++) {
                    if (!seen.add(forms[f])) continue;
                    var labels = net.encode(forms[f]);
                    if (labels == null || labels.length > T) continue;
                    var c = new HwCandidate(w, viterbi(lp, T, C, labels));
                    c.text = forms[f];
                    pre.add(c);
                }
            }
            pre.sort((a, b) => a.score < b.score ? -1 : (a.score > b.score ? 1 : 0));
            while (pre.size > 40) pre.remove_at(pre.size - 1);
            if (dictionary && use_dictionary) {
                var lex = dictionary_lexicon();
                foreach (string form in lex.search(lp, T, C, 40)) {
                    string w = form.down();
                    var forms = new Gee.ArrayList<string>();
                    forms.add(form);
                    if (caps) forms.add(form.up());
                    foreach (string f in forms) {
                        if (!seen.add(f)) continue;
                        var c = new HwCandidate(w, 0);
                        c.text = f;
                        pre.add(c);
                    }
                }
            }
            foreach (var c in pre) {
                var labels = net.encode(c.text);
                c.score = net.nll(lp, T, labels) - (note_words.contains(c.word) ? note_bonus : 0);
            }
            pre.sort((a, b) => a.score < b.score ? -1 : (a.score > b.score ? 1 : 0));
            double gscore = double.INFINITY;
            var glabels = net.encode(greedy);
            if (greedy != "" && glabels != null) gscore = net.nll(lp, T, glabels);
            int digits = 0, others = 0, letters = 0;
            int gi = 0;
            unichar gc;
            while (greedy.get_next_char(ref gi, out gc)) {
                if (gc.isdigit()) digits++;
                else if (gc.isalpha()) letters++;
                else if (gc != ' ') others++;
            }
            bool symbols = digits > 0 || others > letters;
            var raw = new HwCandidate(greedy, gscore + (symbols ? symbol_margin : oov_margin));
            raw.text = greedy;
            if (greedy.strip().contains(" ")) raw.cuts = net.space_cuts(lp, T, left, scale);
            bool raw_added = false;
            foreach (var c in pre) {
                if (!raw_added && greedy != "" && raw.score < c.score) {
                    result.add(raw);
                    raw_added = true;
                }
                if (c.text == greedy) raw_added = true;
                if (result.size < top) result.add(c);
            }
            if (!raw_added && greedy != "" && result.size < top) result.add(raw);
            while (result.size > top) result.remove_at(result.size - 1);
            return result;
        }

        private class NetLine {
            public Gee.ArrayList<Gee.ArrayList<Stroke>> chunks = new Gee.ArrayList<Gee.ArrayList<Stroke>>();
            public Gee.ArrayList<bool> sure = new Gee.ArrayList<bool>();
        }

        private NetLine net_words(Cluster line) {
            var res = new NetLine();
            var cols = columns_of(line);
            if (cols.size == 0) return res;
            double baseline, xh;
            core_band(line, out baseline, out xh);
            xh = double.max(xh, line.height * 0.2);
            var gaps = new double[int.max(0, cols.size - 1)];
            double reach = -double.MAX;
            for (int i = 0; i < cols.size; i++) {
                if (i > 0) gaps[i - 1] = cols[i].x0 - reach;
                reach = double.max(reach, cols[i].x1);
            }
            double median = 0;
            if (gaps.length > 0) {
                var sorted = gaps.copy();
                sort_doubles(sorted);
                median = sorted[sorted.length / 2];
            }
            double low = double.max(net_min_gap * xh, gaps.length >= 3 ? 1.6 * median : 0);
            var cur = new Gee.ArrayList<Stroke>();
            for (int i = 0; i < cols.size; i++) {
                if (i > 0 && gaps[i - 1] > double.min(low, net_word_gap * xh)) {
                    res.chunks.add(cur);
                    res.sure.add(gaps[i - 1] > net_word_gap * xh);
                    cur = new Gee.ArrayList<Stroke>();
                }
                cur.add_all(cols[i].strokes);
            }
            res.chunks.add(cur);
            return res;
        }

        private static Gee.ArrayList<Gee.ArrayList<Stroke>> cut_strokes(Gee.List<Stroke> group, double[] cuts) {
            double gx0 = double.MAX, gy0 = double.MAX, gx1 = -double.MAX, gy1 = -double.MAX;
            foreach (var s in group) foreach (var p in s.points) {
                gx0 = double.min(gx0, p.x);
                gx1 = double.max(gx1, p.x);
                gy0 = double.min(gy0, p.y);
                gy1 = double.max(gy1, p.y);
            }
            double gh = double.max(1e-3, gy1 - gy0);
            double bin = gh / 40.0;
            int nb = (int) ((gx1 - gx0) / bin) + 1;
            var hist = new int[nb];
            foreach (var p in resample_points(group, bin * 0.5)) hist[((int) ((p.x - gx0) / bin)).clamp(0, nb - 1)]++;
            for (int c = 0; c < cuts.length; c++) {
                int center = ((int) ((cuts[c] - gx0) / bin)).clamp(0, nb - 1);
                int reach = (int) (0.6 * gh / bin);
                int best = center;
                double best_cost = double.MAX;
                for (int b = int.max(0, center - reach); b <= int.min(nb - 1, center + reach); b++) {
                    double cost = hist[b] + 0.02 * (b - center).abs();
                    if (cost < best_cost) {
                        best_cost = cost;
                        best = b;
                    }
                }
                cuts[c] = gx0 + (best + 0.5) * bin;
            }
            var pieces = new Gee.ArrayList<Gee.ArrayList<Stroke>>();
            for (int i = 0; i <= cuts.length; i++) pieces.add(new Gee.ArrayList<Stroke>());
            foreach (var s in group) {
                Stroke? cur = null;
                int at = -1;
                foreach (var p in s.points) {
                    int k = 0;
                    while (k < cuts.length && p.x > cuts[k]) k++;
                    if (cur == null || k != at) {
                        cur = new Stroke();
                        cur.tool = s.tool;
                        pieces[k].add(cur);
                        at = k;
                    }
                    cur.points.add(new InkPoint(p.x, p.y));
                }
            }
            var out = new Gee.ArrayList<Gee.ArrayList<Stroke>>();
            foreach (var piece in pieces) if (piece.size > 0) out.add(piece);
            return out;
        }

        private Gee.HashMap<string, HwCandidate?> word_memo = new Gee.HashMap<string, HwCandidate?>();

        private HwCandidate? best_word(Gee.List<Stroke> group, bool split_spaces = true) {
            var key = new StringBuilder(split_spaces ? "s" : "w");
            foreach (var st in group) key.append_printf(":%p:%d", st, st.points.size);
            if (word_memo.has_key(key.str)) return word_memo[key.str];
            var res = best_word_uncached(group, split_spaces);
            word_memo[key.str] = res;
            return res;
        }

        private HwCandidate? best_word_uncached(Gee.List<Stroke> group, bool split_spaces) {
            var learned = learned_match(group);
            if (learned != null) {
                learned.score = 0;
                return learned;
            }
            var cands = net_candidates(group, 1, true);
            if (cands.size == 0) return null;
            var c = cands[0];
            if (split_spaces && c.cuts != null && c.cuts.length > 0) {
                var texts = new Gee.ArrayList<string>();
                double total = 0;
                foreach (var piece in cut_strokes(group, c.cuts)) {
                    var w = best_word(piece, false);
                    if (w == null || w.text.strip() == "") continue;
                    texts.add(w.text.strip());
                    total += w.score;
                }
                if (texts.size > 0) {
                    var joined = new HwCandidate(string.joinv(" ", texts.to_array()), total + split_penalty * (texts.size - 1));
                    if (joined.score <= c.score + oov_margin) return joined;
                }
            }
            return c;
        }

        private HwCandidate? learned_match(Gee.List<Stroke> strokes) {
            if (samples.size == 0) return null;
            var ink = features_of_strokes(strokes);
            if (ink == null) return null;
            HwCandidate? learned = null;
            foreach (var s in samples) {
                double d = dtw(ink, s.features);
                double ar = Math.fabs(Math.log(ink.aspect / double.max(1e-3, s.features.aspect)));
                d = (d + aspect_weight * ar) * sample_prior;
                if (learned == null || d < learned.score) learned = new HwCandidate(s.text, d);
            }
            return learned != null && learned.score < SAMPLE_OK ? learned : null;
        }

        private HwLexicon dictionary_lexicon() {
            load_dictionaries();
            lock (lexicon) {
                if (lexicon == null || lexicon_words != dict_words.size) {
                    var lex = new HwLexicon();
                    foreach (string w in dict_words) {
                        foreach (string f in new string[] { w, upper_first(w) }) {
                            var labels = net.encode(f);
                            if (labels != null) lex.add(f, labels);
                        }
                    }
                    lexicon = lex;
                    lexicon_words = dict_words.size;
                }
            }
            return lexicon;
        }

        private string recognize_net(Gee.List<Stroke> strokes) {
            word_memo.clear();
            var sb = new StringBuilder();
            foreach (var line in lines_of(strokes)) {
                var nl = net_words(line);
                var parts = new Gee.ArrayList<string>();
                var group = new Gee.ArrayList<Stroke>();
                HwCandidate? best = null;
                for (int i = 0; i < nl.chunks.size; i++) {
                    var chunk = nl.chunks[i];
                    if (group.size == 0) {
                        group.add_all(chunk);
                        best = best_word(group);
                        continue;
                    }
                    bool split = nl.sure[i - 1];
                    HwCandidate? merged = null;
                    HwCandidate? alone = null;
                    var joined = new Gee.ArrayList<Stroke>();
                    if (!split) {
                        joined.add_all(group);
                        joined.add_all(chunk);
                        merged = best_word(joined);
                        alone = best_word(chunk);
                        double split_cost = (best != null ? best.score : NET_UNKNOWN) + (alone != null ? alone.score : NET_UNKNOWN) + split_penalty;
                        double merge_cost = merged != null ? merged.score : double.INFINITY;
                        split = split_cost < merge_cost;
                    }
                    if (split) {
                        if (best != null && best.text != "") parts.add(best.text);
                        group = new Gee.ArrayList<Stroke>();
                        group.add_all(chunk);
                        best = alone ?? best_word(group);
                    } else {
                        group = joined;
                        best = merged;
                    }
                }
                if (best != null && best.text != "") parts.add(best.text);
                if (parts.size == 0) continue;
                if (sb.len > 0) sb.append("\n");
                sb.append(string.joinv(" ", parts.to_array()));
            }
            return sb.str;
        }

        public string recognize(Gee.List<Stroke> strokes) {
            ensure_net();
            if (use_net && net != null) return recognize_net(strokes);
            var sb = new StringBuilder();
            foreach (var line in lines_of(strokes)) {
                double baseline, xh;
                core_band(line, out baseline, out xh);
                var parts = new Gee.ArrayList<string>();
                foreach (var seg in segment_line(line)) {
                    string text;
                    if (seg.best != null && seg.best.score < WORD_OK) {
                        text = seg.best.text;
                    } else {
                        var chars = new StringBuilder();
                        foreach (var c in seg.parts) chars.append(classify_char(c, baseline, xh));
                        text = chars.str;
                        if (text == "" && seg.best != null) text = seg.best.text;
                    }
                    if (text != "") parts.add(text);
                }
                if (parts.size == 0) continue;
                if (sb.len > 0) sb.append("\n");
                sb.append(string.joinv(" ", parts.to_array()));
            }
            return sb.str;
        }

        public async string recognize_async(Gee.List<Stroke> strokes) {
            var copy = new Gee.ArrayList<Stroke>();
            foreach (var s in strokes) copy.add(s.copy());
            string result = "";
            SourceFunc resume = recognize_async.callback;
            busy = true;
            new Thread<bool>("handwriting", () => {
                result = recognize(copy);
                Idle.add((owned) resume);
                return true;
            });
            yield;
            busy = false;
            return result;
        }

        public int learn_text(Gee.List<Stroke> strokes, string text) {
            var lines = lines_of(strokes);
            var text_lines = new Gee.ArrayList<Gee.ArrayList<string>>();
            foreach (string l in text.strip().split("\n")) {
                var words = new Gee.ArrayList<string>();
                foreach (string w in l.split_set(" \t")) if (w.strip() != "") words.add(w.strip());
                if (words.size > 0) text_lines.add(words);
            }
            if (text_lines.size == 0) return 0;
            if (text_lines.size != lines.size) {
                var merged = new Gee.ArrayList<string>();
                foreach (var l in text_lines) merged.add_all(l);
                text_lines.clear();
                text_lines.add(merged);
                var all = new Cluster();
                foreach (var l in lines) all.merge(l);
                lines.clear();
                lines.add(all);
            }
            var list = new Gee.ArrayList<string>();
            foreach (var l in text_lines) list.add_all(l);
            add_words(list);
            int learned = 0;
            for (int i = 0; i < lines.size; i++) {
                var words = text_lines[i];
                var groups = split_words(lines[i], words.size);
                if (groups.size != words.size) {
                    learn(lines[i].strokes, string.joinv(" ", words.to_array()));
                    learned++;
                    continue;
                }
                for (int k = 0; k < words.size; k++) {
                    learn(groups[k], words[k]);
                    learned++;
                }
            }
            return learned;
        }

        private Gee.ArrayList<Gee.ArrayList<Stroke>> split_words(Cluster line, int count) {
            var cols = columns_of(line);
            var groups = new Gee.ArrayList<Gee.ArrayList<Stroke>>();
            if (cols.size < count) return groups;
            var gaps = new double[int.max(0, cols.size - 1)];
            double reach = -double.MAX;
            for (int i = 0; i < cols.size; i++) {
                if (i > 0) gaps[i - 1] = cols[i].x0 - reach;
                reach = double.max(reach, cols[i].x1);
            }
            var cuts = new Gee.HashSet<int>();
            for (int k = 0; k < count - 1; k++) {
                int best = -1;
                for (int i = 0; i < gaps.length; i++) if (!cuts.contains(i) && (best < 0 || gaps[i] > gaps[best])) best = i;
                if (best < 0) break;
                cuts.add(best);
            }
            var cur = new Gee.ArrayList<Stroke>();
            for (int i = 0; i < cols.size; i++) {
                cur.add_all(cols[i].strokes);
                if (cuts.contains(i) || i == cols.size - 1) {
                    groups.add(cur);
                    cur = new Gee.ArrayList<Stroke>();
                }
            }
            return groups;
        }

        public void learn(Gee.List<Stroke> strokes, string text) {
            var f = features_of_strokes(strokes);
            if (f == null || text.strip() == "") return;
            samples.add(new HwSample(text.strip(), f));
            save_user();
        }

        public int dictionary_size() {
            return dict_words.size;
        }

        public int sample_count() {
            return samples.size;
        }

        public void forget_samples() {
            samples.clear();
            save_user();
        }

        public void reload_user() {
            samples.clear();
            if (user_path == null || !FileUtils.test(user_path, FileTest.EXISTS)) return;
            try {
                var parser = new Json.Parser();
                parser.load_from_file(user_path);
                var root = parser.get_root();
                if (root == null || root.get_node_type() != Json.NodeType.ARRAY) return;
                foreach (var n in root.get_array().get_elements()) {
                    var o = n.get_object();
                    var arr = o.get_array_member("data");
                    int cols = (int) (arr.get_length() / F);
                    if (cols == 0) continue;
                    var f = new HwFeatures(cols);
                    for (int i = 0; i < cols * F; i++) f.data[i] = arr.get_double_element(i);
                    f.aspect = o.get_double_member("aspect");
                    samples.add(new HwSample(o.get_string_member("text"), f));
                }
            } catch (Error e) {
                warning("handwriting samples: %s", e.message);
            }
        }

        private void save_user() {
            if (user_path == null) return;
            var arr = new Json.Array();
            foreach (var s in samples) {
                var o = new Json.Object();
                o.set_string_member("text", s.text);
                o.set_double_member("aspect", s.features.aspect);
                var d = new Json.Array();
                foreach (double v in s.features.data) d.add_double_element(v);
                o.set_array_member("data", d);
                arr.add_object_element(o);
            }
            var node = new Json.Node(Json.NodeType.ARRAY);
            node.set_array(arr);
            try {
                DirUtils.create_with_parents(Path.get_dirname(user_path), 0700);
                FileUtils.set_contents(user_path, Json.to_string(node, false));
            } catch (Error e) {
                warning("handwriting samples: %s", e.message);
            }
        }

        private class HwTrace {
            public Gee.ArrayList<Stroke> strokes;
            public int baseline;
        }

        private static Gee.HashMap<string, HwTrace?> traces;

        private static HwTrace? glyph_trace(string ch, string font, double size) {
            if (traces == null) traces = new Gee.HashMap<string, HwTrace?>();
            string key = "%s\n%g\n%s".printf(font, size, ch);
            if (traces.has_key(key)) return traces[key];
            HwTrace? t = null;
            var bm = render_text(ch, font, size);
            if (bm != null) {
                thin(bm.grid, bm.w, bm.h);
                t = new HwTrace();
                t.strokes = trace(bm.grid, bm.w, bm.h, 0, 0, 1.0);
                t.baseline = bm.baseline;
            }
            traces[key] = t;
            return t;
        }

        public static Gee.ArrayList<Stroke> synthesize(string text, string font, double size, double slant, double jitter, bool connect, uint32 seed) {
            var rand = new Rand.with_seed(seed);
            var result = new Gee.ArrayList<Stroke>();
            var probe = new Cairo.ImageSurface(Cairo.Format.A8, 8, 8);
            var pcr = new Cairo.Context(probe);
            var layout = Pango.cairo_create_layout(pcr);
            var fd = Pango.FontDescription.from_string(font);
            fd.set_absolute_size((int) (size * Pango.SCALE));
            layout.set_font_description(fd);
            layout.set_text(text, -1);
            int baseline = layout.get_baseline() / Pango.SCALE;
            int index = 0;
            unichar c;
            Stroke? prev_end_stroke = null;
            while (text.get_next_char(ref index, out c)) {
                int start = index - c.to_string().length;
                var pos = layout.index_to_pos(start);
                if (c == ' ') {
                    prev_end_stroke = null;
                    continue;
                }
                var traced = glyph_trace(c.to_string(), font, size);
                if (traced == null) continue;
                double ox = pos.x / (double) Pango.SCALE;
                double oy = baseline - traced.baseline;
                var strokes = new Gee.ArrayList<Stroke>();
                foreach (var t in traced.strokes) {
                    var cp = new Stroke();
                    foreach (var p in t.points) cp.points.add(new InkPoint(p.x + ox, p.y + oy));
                    strokes.add(cp);
                }
                if (strokes.size == 0) continue;
                if (connect && prev_end_stroke != null) {
                    var a = prev_end_stroke.points[prev_end_stroke.points.size - 1];
                    InkPoint? b = null;
                    foreach (var s in strokes) foreach (var p in s.points) if (b == null || p.x < b.x) b = p;
                    var link = new Stroke();
                    link.points.add(new InkPoint(a.x, a.y));
                    link.points.add(new InkPoint((a.x + b.x) / 2, baseline - size * 0.05));
                    link.points.add(new InkPoint(b.x, b.y));
                    result.add(link);
                }
                Stroke? right = null;
                double rx = -double.MAX;
                foreach (var s in strokes) {
                    foreach (var p in s.points) {
                        if (p.x > rx && p.y > baseline - size * 0.45) {
                            rx = p.x;
                            right = s;
                        }
                    }
                    result.add(s);
                }
                if (right != null) {
                    var tail = new Stroke();
                    InkPoint? rp = null;
                    foreach (var p in right.points) if (rp == null || p.x > rp.x) rp = p;
                    tail.points.add(rp);
                    prev_end_stroke = tail;
                }
            }
            double dx = rand.double_range(-jitter, jitter);
            double dy = rand.double_range(-jitter, jitter);
            foreach (var s in result) {
                foreach (var p in s.points) {
                    double y = p.y;
                    p.x = p.x + slant * (baseline - y) + dx + rand.double_range(-jitter, jitter) * 0.3;
                    p.y = y + dy + rand.double_range(-jitter, jitter) * 0.3;
                    dx += rand.double_range(-0.15, 0.15);
                    dy += rand.double_range(-0.15, 0.15);
                    dx = dx.clamp(-jitter, jitter);
                    dy = dy.clamp(-jitter, jitter);
                }
            }
            return result;
        }
    }
}
